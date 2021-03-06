#' SparCC
#'
#' reimplementation of SparCC in R
#'
#' @param data count data
#' @param iter number of iterations to compute median correlation
#' @param inner_iter number of iterations for the inner loop
#' @export
sparcc <- function(data, iter=20, inner_iter=10, th=.1) {
##
#  without all the 'frills'
    sparccs <-
     lapply(1:iter, function(i)
         sparccinner(t(apply(data, 1, norm_diric)), iter=inner_iter, th=th))
    # collect
    cors <- array(unlist(lapply(sparccs, function(x) x$Cor)),
                 c(ncol(data),ncol(data),iter))
    corMed <- apply(cors, 1:2, median)
    covs <- array(unlist(lapply(sparccs, function(x) x$Cov)),
                 c(ncol(data),ncol(data),iter))
    covMed <- apply(cors, 1:2, median)

    covMed <- cor2cov(corMed, sqrt(diag(covMed)))
    list(Cov=covMed, Cor=corMed)
}

#' SparCC bootstraps
#'
#' Bootstrapped Sparcc to get empirical and null distributions for correlations
#'
#' @param data count data matrix
#' @param sparcc.params named list of parameters passed to sparcc
#' @param statisticboot optional argument to override default bootstrap function
#' @param statisticperm optional argument to override default permute function
#' @return sparccboot object. Pass to \code{pval.sparccboot} to get empirical p-values
#' @export
sparccboot <- function(data, sparcc.params=list(), statisticboot, statisticperm, R, ncpus=1, ...) {
    if (!require('boot')) {
      stop('\'boot\' package is not installed')
    }

    if (missing(statisticboot)) {
        statisticboot <- function(data, indices)
            triu(do.call("sparcc", c(list(data[indices,,drop=FALSE]), sparcc.params))$Cor)
    }
    if (missing(statisticperm)) {
        statisticperm <- function(data, indices)
            triu(do.call("sparcc", c(list(apply(data[indices,], 2, sample)), sparcc.params))$Cor)
    }

    res     <- boot::boot(data, statisticboot, R=R, parallel="multicore", ncpus=ncpus, ...)
    null_av <- boot::boot(data, statisticperm, sim='permutation', R=R, parallel="multicore", ncpus=ncpus)
    class(res) <- 'list'
    structure(c(res, list(null_av=null_av)), class='sparccboot')
}

#' get pvals
#'
#' Compute empirical p-values from \code{sparccboot} output
#'
#' @param x output from sparccboot
#' @param sided compute two sided p-values (one-sided not currently supported)
#' @export
pval.sparccboot <- function(x, sided='both') {
# calculate 1 or 2 way pseudo p-val from boot object
# Args: a boot object
    if (sided != "both") stop("only two-sided currently supported")
    nparams  <- ncol(x$t)
    tmeans   <- colMeans(x$null_av$t)
#    check to see whether Aitchison variance is unstable -- confirm
#    that sample Aitchison variance is in 95% confidence interval of
#    bootstrapped samples
    niters   <- nrow(x$t)
    ind95    <- max(1,round(.025*niters)):round(.975*niters)
    boot_ord <- apply(x$t, 2, sort)
    boot_ord95 <- boot_ord[ind95,]
    outofrange <- unlist(lapply(1:length(x$t0), function(i) {
            aitvar <- x$t0[i]
            range  <- range(boot_ord95[,i])
            range[1] > aitvar || range[2] < aitvar
        }))
    # calc whether center of mass is above or below the mean
    bs_above <- unlist(lapply(1:nparams, function(i)
                    length(which(x$t[, i] > tmeans[i]))))
    is_above <- bs_above > x$R/2
    cors <- x$t0
#    signedAV[is_above] <- -signedAV[is_above]
    pvals    <- ifelse(is_above, 2*(1-bs_above/x$R), 2*bs_above/x$R)
    pvals[pvals > 1]  <- 1
    pvals[outofrange] <- NaN
    list(cors=cors, pvals=pvals)
}



#' @keywords internal
sparccinner <- function(data.f, T=NULL, iter=10, th=0.1) {
    if (is.null(T))   T  <- av(data.f)
    res.bv <- basis_var(T)
    Vbase  <- res.bv$Vbase
    M      <- res.bv$M
    cbase  <- C_from_V(T, Vbase)
    Cov    <- cbase$Cov
    Cor    <- cbase$Cor

    ## do iterations here
    excluded <- NULL
    for (i in 1:iter) {
        res.excl <- exclude_pairs(Cor, M, th, excluded)
        M <- res.excl$M
        excluded <- res.excl$excluded
        if (res.excl$break_flag) break
        res.bv <- basis_var(T, M=M, excluded=excluded)
        Vbase  <- res.bv$Vbase
        M      <- res.bv$M
        K <- M
        diag(K) <- 1
        cbase  <- C_from_V(T, Vbase)
        Cov    <- cbase$Cov
        Cor    <- cbase$Cor
    }
    list(Cov=Cov, Cor=Cor, i=i, M=M, excluded=excluded)
}

#' @keywords internal
exclude_pairs <- function(Cor, M, th=0.1, excluded=NULL) {
# exclude pairs with high correlations
    break_flag <- FALSE
    C_temp <- abs(Cor - diag(diag(Cor)) )  # abs value / remove diagonal
    if (!is.null(excluded)) C_temp[excluded] <- 0 # set previously excluded correlations to 0
    exclude <- which(abs(C_temp - max(C_temp)) < .Machine$double.eps*100)[1:2]
    if (max(C_temp) > th)  {
        i <- na.exclude(arrayInd(exclude, c(nrow(M), ncol(M)))[,1])
        M[i,i] <- M[i,i] - 1
        excluded_new <- c(excluded, exclude)
    } else {
        excluded_new <- excluded
        break_flag   <- TRUE
    }
    list(M=M, excluded=excluded_new, break_flag=break_flag)
}

#' @keywords internal
basis_cov <- function(data.f) {
# data.f -> relative abundance data
# OTUs in columns, samples in rows (yes, I know this is transpose of normal)
    # first compute aitchison variation
    T <- av(data.f)
    res.bv <- basis_var(T)
    Vbase  <- res.bv$Vbase
    M      <- res.bv$M
    cbase  <- C_from_V(T, Vbase)
    Cov    <- cbase$Cov
    Cor    <- cbase$Cor
    list(Cov=Cov, M=M)
}

#' @keywords internal
basis_var <- function(T, CovMat = matrix(0, nrow(T), ncol(T)),
                      M = matrix(1, nrow(T), ncol(T)) + (diag(ncol(T))*(ncol(T)-2)),
                      excluded = NULL, Vmin=1e-4) {

    if (!is.null(excluded)) {
        T[excluded] <- 0
     #   CovMat[excluded] <- 0
    }
    Ti     <- matrix(rowSums(T))
    CovVec <- matrix(rowSums(CovMat - diag(diag(CovMat)))) # row sum of off diagonals
    M.I <- tryCatch(solve(M), error=function(e) MASS::ginv(M))
    Vbase <- M.I %*% (Ti + 2*CovVec)
    Vbase[Vbase < Vmin] <- Vmin
    list(Vbase=Vbase, M=M)
}

#' @keywords internal
C_from_V <- function(T, Vbase) {
    J      <- matrix(1, nrow(T), ncol(T))
    Vdiag  <- diag(c(Vbase))
    CovMat <- .5*((J %*% Vdiag) + (Vdiag %*% J) - T)
    CovMat <- (CovMat + t(CovMat))/2  # enforce symmetry
    # check that correlations are within -1,1
    CorMat <- cov2cor(CovMat)
    CorMat[abs(CorMat) > 1] <- sign(CorMat[abs(CorMat) > 1])
    CovMat <- cor2cov(CorMat, sqrt(as.vector(Vbase)))
    list(Cov=CovMat, Cor=CorMat)
}

#' @keywords internal
av <- function(data) {
    cov.clr <- cov(clr(data))
    J <- matrix(1, ncol(data), ncol(data))
    (J %*% diag(diag(cov.clr))) + (diag(diag(cov.clr)) %*% J) - (2*cov.clr)
}


#' importFrom VGAM rdiric
#' @export
norm_diric   <- function(x, rep=1) {
    dmat <- VGAM::rdiric(rep, x+1)
    norm_to_total(colMeans(dmat))
}
