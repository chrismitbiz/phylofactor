#' Internal PhyloRegression function for finding the winning edge.
#'
#' @param nset set of nodes
#' @param tree_map mapping cumulative number of nodes in treeList, used to map elements of nset to their appropriate tree in treeList.
#' @param treeList list containing disjoint trees from phylofactor / PhyCA
#' @param treetips number of tips in each tree
#' @param contrast.fcn See \code{\link{PhyloFactor}} or example functions \code{\link{BalanceContrast}}, \code{\link{amalgamate}}
#' @param choice string indicating how we choose the winner. Must be either \code{'var'}, \code{'F'}, or \code{'phyca'}
#' @param method See \code{\link{PhyloFactor}}
#' @param frmla Formula for \code{\link{glm}}. See \code{\link{PhyloFactor}} for more details.
#' @param xx data frame containing non-ILR (\code{Data}) variables used in \code{frmla}
#' @param choice.fcn See \code{\link{PhyloFactor}}
#' @param ... optional input arguments to \code{\link{glm}}
findWinner <- function(nset,tree_map,treeList,treetips,contrast.fcn=NULL,choice,method='glm',frmla=NULL,xx=NULL,choice.fcn=NULL,...){
  
  
  ########### set-up and prime variables #############
  grp <- vector(mode='list',length=2)
  output <- NULL
  Y <- numeric(ncol(TransformedData))
  if (!exists('gg')){
    gg <- NULL #This will be our GLM
  }

  output$stopStatistics <- vector(mode='list',length=length(nset))
  if (choice=='var'){
    output$ExplainedVar=0
  }
  if (choice=='F'){
    output$Fstat=0
  }
  if (choice=='custom'){
    output$objective=-Inf
    if (is.null(choice.fcn)){
      if (is.null(choice.fcn)){
        choice.fcn <- function(y=NULL,X=NULL,PF.output=NULL){
          ch <- NULL
          ch$objective <- 1
          ch$stopStatistics <- 1
          return(ch)
        }
      }
    }
  }
  ####################################################
  
  
  
  
  #################################################### ITERATION OVER nset TO FIND WINNER #############################################################
  iteration=0
  for (nn in nset){
    iteration=iteration+1
    
    
    ############# getting grp - list of group & complement - for node in nset #####
    if (nn>tree_map[1]){
      whichTree <- max(which(tree_map<nn))+1
      if ((nn-tree_map[[whichTree-1]])==treetips[whichTree]+1){ 
        #This prevents us from drawing the root of a subtree, which has no meaningful ILR transform. 
        next 
      }
      grp[[1]] <- phangorn::Descendants(treeList[[whichTree]],node=(nn-tree_map[whichTree-1]))[[1]]
    } else {
      whichTree <- 1
      if (nn==(treetips[1]+1)){ 
        #This prevents us from drawing the root of a subtree, which has no meaningful ILR transform. 
        next 
      }
      grp[[1]] <- phangorn::Descendants(treeList[[1]],node=nn)[[1]]
    }
    grp[[2]] <- setdiff(1:treetips[whichTree],grp[[1]])
    grp <- lapply(grp,FUN=function(x,tree) tree$tip.label[x],tree=treeList[[whichTree]])
    #This converts numbered grps of tip-labels for trees in treeList to otus that correspond to rownames in Data.
    ###############################################################################
      
      
      
      ####################### ILR-transform the data ################################
     if (is.null(contrast.fcn)){ 
       Y <- BalanceContrast(grp,TransformedData)
     } else {
       Y <- contrast.fcn(grp,TransformedData)
     }
      ################################################################################
      
      
      #################### Applying Choice Function to Y #############################
      ########### And updating output if objective > output$objective ################
      if (choice %in% c('var','F') & method!='max.var'){ ########### 2 of 3 default choice.fcns
        ################ Making data frame for regression #######
            if (!exists('dataset')){
              dataset <- c(list(Y),as.list(xx))
              names(dataset) <- c('Data',names(xx))
              dataset <- stats::model.frame(frmla,data = dataset)
            } else {  #dataset already exists - we just need to update Data
              dataset$Data <- Y
            }
        #########################################################
        args <- list('data'=dataset,'formula'=frmla,...)
        gg=do.call(stats::glm,args)
        #########################################################
        
        ############# Update output if objective is larger #######
        stats=getStats(gg,y=Y)
        output$stopStatistics[iteration] <- stats['Pval']
          if (choice=='var'){
            if (stats['ExplainedVar']>output$ExplainedVar){
              output$grp <- grp
              output$ExplainedVar <- stats['ExplainedVar']
            }
          } else {
            if (stats['F']>output$Fstat){
              output$grp <- grp
              output$Fstat <- stats['F']
            }
          }
        #########################################################
        
        
      } else if (method=='max.var'){ #PhyCA
        v=stats::var(Y)
        if (v>output$ExplainedVar){
          output$grp <- grp
          output$ExplainedVar <- v
          output$Y <- Y
        }
      } else {
        
        ################# choice.fcn ######################
        ch <- choice.fcn(y=Y,X=xx,PF.output=F,...)
        obj <- ch$objective
        output$stopStatistics[[iteration]] <- ch$stopStatistics
        ################# update if obj ###################
        if (obj>output$objective){
          output$grp <- grp
          output$objective <- obj
        }
      }  
    
  }
  #################################################### ITERATION OVER nset TO FIND WINNER #############################################################

  return(output)
}