#' Phylofactorization of vector data using two-sample tests
#' 
#' @export
#' @param Z Vector of data. 
#' @param tree phylo class object
#' @param nfactors number of factors to compute
#' @param method string indicating two-sample test two use. Can take values of "contrast" (default), "Fisher", "Wilcox", 't.test', or "custom", indicating the two-sample test to be used.
#' @param TestFunction optional input customized test function, taking input \code{{grps,tree,Z,PF.output,..}} and output objective omega. \code{grps} is a two-element list containing indexes for each group; see \code{\link{getPhyloGroups}}. PF.output is a logical: the output from PF.output=T should be a P-value and can be input into the \code{stop.fcn}.
#' @param ncores number of cores to use for parallelization
#' @param stop.fcn stop function taking as input the output from \code{TestFunction} when \code{PF.output=T} and returning logical where an output of \code{TRUE} will stop phylofactorization. Inputting character string "KS", will use KS-test on the P-values output from \code{TestFunction}.
#' @param cluster.depends expression loading dependencies for \code{TestFunction} onto cluster.
#' @param Metropolis logical. If true, phylofactorization will be implemented by stochastically sample edges using \code{sampleFcn}.
#' @param sampleFcn function taking argument \code{omegas}, which is used to implement Metropolis phylofactorization.
#' @param lambda Parameter for default Metropolis phylofactorization in which groups are drawn with probability proportional to omega^lambda.
#' @param ... additional arguments passed to \code{TestFunction}
#' @examples 
#' library(phylofactor)
#' library(ggtree)
#' library(viridis)
#' set.seed(1)
#' D <- 300
#' tree <- rtree(D)
#' n1 <- 477
#' n2 <- 332
#' c1 <- phangorn::Descendants(tree,n1,'tips')[[1]]
#' c2 <- phangorn::Descendants(tree,n2,'tips')[[1]]
#' 
#' Z <- rnorm(D)
#' Z[c1] <- Z[c1]+1
#' Z[c2] <- Z[c2]-2
#' 
#' pf <- twoSampleFactor(Z,tree,2,ncores=2)
#' cbind(c(length(c2),length(c1)),pf$factors)
#' pp <- pf.tree(pf,layout='rectangular')$ggplot
#' 
#' tipcolors <- rgb(ecdf(Z)(Z),0,1-ecdf(Z)(Z))
#' pp+geom_cladelabel(node=n1,'clade_1')+
#'    geom_cladelabel(node=n2,'clade_2')+
#'    geom_tippoint(color=tipcolors,size=3)
#'    
#'    
#'    
#' ############# binary data #################
#' Z <- rbinom(D,1,0.3)
#' Z[c1] <- rbinom(length(c1),1,0.9)
#' Z[c2] <- 0
#' 
#' pf <- twoSampleFactor(Z,tree,nfactors=2,method='Fisher',alternative='two.sided')
#' pp <- pf.tree(pf,layout='rectangular')$ggplot
#' 
#' tipcolors <- viridis(2)[Z+1]
#' pp+geom_cladelabel(node=n1,'clade_1')+
#'    geom_cladelabel(node=n2,'clade_2')+
#'    geom_tippoint(color=tipcolors,size=3)
twoSampleFactor <- function(Z,tree,nfactors,method='contrast',TestFunction=NULL,ncores=NULL,stop.fcn=NULL,cluster.depends='',Metropolis=F,sampleFcn=NULL,lambda=1,...){
  
  if (!is.null(TestFunction)){
    method <- 'custom'
  }
  
  if (method=='contrast'){
    TestFunction <- function(grps,Z,PF.output=F,...){
      if (!PF.output){
        return(abs(matrix(ilrvec(grps,length(Z)),nrow=1) %*% Z))
      } else {
        return(stats::t.test(Z[grps[[1]]],Z[grps[[2]]],var.equal = T,...)$p.value)
      }
    }
    
  } else if (method=='Fisher'){
    TestFunction <- function(grps,Z,PF.output=F,...){
      s1 <- S4Vectors::na.omit(Z[grps[[1]]])
      s2 <- S4Vectors::na.omit(Z[grps[[2]]])
      n1 <- sum(s1)
      n2 <- sum(s2)
      p <- tryCatch(stats::fisher.test(matrix(c(n1,length(s1)-n1,n2,length(s2)-n2),ncol=2),...)$p.value,
                     error=function(e) 1)
      if (!PF.output){
        return(1/p)
      } else {
        return(p)
      }
    }
  } else if (method=='Wilcox'){
    TestFunction <- function(grps,Z,PF.output=F,...){
      if (!PF.output){
        s <- 1/stats::wilcox.test(S4Vectors::na.omit(Z[grps[[1]]]),S4Vectors::na.omit(Z[grps[[2]]]))$p.value
      } else {
        s <- stats::wilcox.test(Z[grps[[1]]],Z[grps[[2]]])$p.value
      }
      return(s)
    }
  } else if (method=='t.test'){
    TestFunction <- function(grps,Z,PF.output=F,...){
      if (!PF.output){
        return(tryCatch(stats::t.test(Z[grps[[1]]],Z[grps[[2]]],...)$statistic,
                        error=function(e) 0))
      } else {
        return(tryCatch(stats::t.test(Z[grps[[1]]],Z[grps[[2]]],...)$p.value,
                        error=function(e) 0))
      }
    }
  }else if (method!='custom'){
    stop('unknown input method')
  }
  
  if (Metropolis & is.null(sampleFcn)){
    sampleFcn <- function(omegas,lambda) sample(length(omegas),1,prob=omegas^lambda)
  }
  
  if (!is.null(ncores)){
    cl <- phyloFcluster(ncores)
    parallel::clusterExport(cl,varlist = 'cluster.depends',envir = environment())
    parallel::clusterEvalQ(cl,eval(parse(text=cluster.depends)))
  }
  
  treeList <- list(tree)
  binList <- list(1:ape::Ntip(tree))
  Grps=getPhyloGroups(tree)
  output <- NULL
  pfs=0
  tm <- Sys.time()
  while (pfs < min(length(Z)-1,nfactors)){
    
    if (pfs>=1){
      treeList <- updateTreeList(treeList,binList,grp,tree,skip.check=T)
      binList <- updateBinList(binList,grp)
      Grps <- getNewGroups(tree,treeList,binList)
    }
    
    if (is.null(ncores)){
      omegas <- sapply(Grps,FUN=TestFunction,Z=Z,...)
    } else {
      omegas <- parallel::parSapply(cl,Grps,TestFunction,Z=Z,...)
    }
    
    if (!Metropolis){
      ix <- which.max(omegas)
      best.grp <- Grps[[ix]]
      P <- TestFunction(best.grp,Z=Z,PF.output=T,...)
    } else {
      ix <- sampleFcn(omegas,lambda)
      best.grp <- Grps[[ix]]
      P <- TestFunction(best.grp,Z=Z,PF.output=T,...)
    }
    
    output$pvals <- c(output$pvals,P)
    output$objective <- c(output$objective,omegas[ix])
    grp <- getLabelledGrp(tree=tree,Groups=best.grp)
    output$groups <- c(output$groups,list(best.grp))
    
    grpInfo <- matrix(c(names(grp)),nrow=2)
    output$factors <- cbind(output$factors,grpInfo)
    
    pfs=pfs+1
    tm2 <- Sys.time()
    time.elapsed <- signif(difftime(tm2,tm,units = 'mins'),3)
    if (pfs==1){
      GUI.notification <- paste('\r',pfs,'factor completed in',time.elapsed,'minutes.   ')
    } else {
      GUI.notification <- paste('\r',pfs,'factors completed in',time.elapsed,'minutes.    ')
    }
    
    GUI.notification <- paste(GUI.notification,'Estimated time of completion:',
                                as.character(tm+difftime(tm2,tm)*nfactors/pfs),
                                '  \r')
    
    cat(GUI.notification)
    utils::flush.console()
  }
  
  
  if (!is.null(ncores)){
    parallel::stopCluster(cl)
    rm('cl')
  }
  
  if (!is.null(output$factors)){
    colnames(output$factors)=sapply(as.list(1:pfs),FUN=function(a,b) paste(b,a,sep=' '),b='Factor',simplify=T)
    rownames(output$factors)=c('Group1','Group2')
  }
  output$factors <- t(output$factors) %>% as.data.frame  
  V <- NULL
  for (i in 1:length(output$groups)){
    V <- cbind(V,ilrvec(output$groups[[i]],ape::Ntip(tree)))
  }
  
  output$basis <- V
  output$bins <- bins(V)
  output$tree <- tree
  output$nfactors <- pfs
  output$Data <- matrix(Z,ncol=1)
  output$model.fcn <- TestFunction
  output$method <- method
  output$additional.arguments <- list(...)
  names(output$Data) <- tree$tip.label
  output$phylofactor.fcn <- 'twoSampleFactor'
  class(output) <- 'phylofactor'
  
  return(output)
}
