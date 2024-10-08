# ------------------ The function GPCor is for calculating the correlation of gene-peak pairs
############## INPUT: 1. peak-cell matrix; 2. scRNA-seq matrix or gene activity matrix; 3. reference genome in Granges form
############## OUTPUT: A dataframe of peak-gene correlation
GPCor <- function(cre.mat=cre.mat,  # peak-cell matrix
                  exp.mat=rna.mat,  # scRNA-seq matrix or gene activity matrix
                  normalizeRNAMat=T, # if the rna matrix need normalization
                  genome = "macFas5", # reference genome, must be one of "hg19", "mm10", or "hg38"
                  windowPadSize = 100000, # base pairs padded on either side of gene TSS
                  proPadSize = 2000, # base pairs padded on either side of gene TSS for enhancer
                  nCores=8 # How many registerCores to use
){
  # check genome
  if(!genome %in% c("hg19", "hg38", "mm10", "macFas5")){
    stop("You must specify one of hg19, hg38, mm10, or macFas5 as a genome build for currently supported TSS annotations..\n")
  }
  
  # Normalize input matrix
  cre.mat.cc <- centerCounts(cre.mat)
  if(normalizeRNAMat==T)
    rna.mat <- NormalizeData(exp.mat, normalization.method = "LogNormalize", scale.factor = 10000) 
  # Create a se object for normalized scATAC data
  peaks <- StringToGRanges(rownames(cre.mat))
  peaks$Peak <- rownames(cre.mat)
  names(peaks) <- rownames(cre.mat)
  se <- SummarizedExperiment::SummarizedExperiment(
    assays = list(counts = cre.mat.cc),
    rowRanges = peaks
  )
  
  # genePeak overlap
  Ov <- genePeakOv(ATAC.se = se,
                   RNAmat = rna.mat,
                   genome = genome,
                   windowPadSize = windowPadSize,
                   proPadSize = proPadSize)
  
  #---
  genes <- as.character(unique(Ov$gene_name))
  
  future::plan("multicore", workers = as.numeric(nCores))
  GPTab <- pbapply::pblapply(genes, function(g) {
    Ovd <- Ov %>% filter(gene_name == g)
    ObsCor <- PeakGeneCor(ATAC = cre.mat,
                          RNA = rna.mat,
                          peakRanges = peaks,
                          OV = Ovd)
    return(ObsCor)
  }, cl = "future") %>% bind_rows() %>% tibble::remove_rownames()
  
  return(GPTab)
}

# ------------------ The function GPCor is for identifying the putative enhancer cluster that regulate the same target gene
############## INPUT: 1. a dataframe of peak-gene correlation; 2. reference genome in Granges form
############## OUTPUT: A list of enhancer cluster
FindNode <- function(GPTab, 
                     genome = "macFas5", # reference genome, must be one of "hg19", "mm10", or "hg38"
                     estimate = 0, # the threshold value of peak-gene correlation to determine whether the peak-gene pair is significantly correlated
                     proPadSize = 2000, # base pairs padded on either side of gene TSS for enhancer
                     FDR = 0.05 # the threshold value of FDR to determine whether the peak-gene pair is significantly correlated
){
  # check genome
  if(!genome %in% c("hg19", "hg38", "mm10", "macFas5")){
    stop("You must specify one of hg19, hg38, mm10, or macFas5 as a genome build for currently supported TSS annotations..\n")
  }
  if(genome %in% c("hg19", "hg38", "mm10", "macFas5")){
    load(paste0('../data/', genome, '_refSeq.Rdata'))
  }
  
  # ------------ select significantly correlated peak-gene pairs
  GPTabFilt <- GPTab[which(GPTab$estimate != "NA" & GPTab$class == "corr" & GPTab$estimate > estimate & GPTab$FDR < FDR),]
  # ------------ throw away promoter
  peakRanges <- StringToGRanges(GPTabFilt$Peak)
  peakSummits <- resize(peakRanges,width = 1,fix = "center")
  GPTabFilt$Summits <- GRangesToString(peakSummits)
  all <- resize(get(paste0(genome, 'TSSRanges')), width = proPadSize*2, fix = 'center')
  tmp <- peakSummits[which(peakSummits %over% all)]
  if(length(tmp)>0){
    GPTabFilt <- GPTabFilt[-which(GPTabFilt$Summits %in% GRangesToString(tmp)),]
  }
  if(length(tmp)==0){
    GPTabFilt <- GPTabFilt
  }

  # ------------ Remove multi-mapping peaks (force 1-1 mapping)
  cat("Keeping max correlation for multi-mapping peaks ..\n")
  GPTabFilt <- GPTabFilt %>% group_by(Peak) %>% filter(estimate==max(estimate))
  
  return(GPTabFilt)
}




# ------------------ This step is to find significantly co-accessible enhancer pairs, as the edges of enhancer networks.
############## INPUT: 1. peak-cell matrix; 2. a list of enhancer cluster; 3. cell metadata; 4. cell coordinates
############## OUTPUT: A data frame of co-accessibility scores
FindEdge <- function(peaks.mat=cre.mat,  # peak-cell matrix
                     GPPair=GPPair, # A list of enhancer cluster, the output of Step.2
                     cellinfo=NULL,  # A data frame containing attributes of individual cells.
                     k=50, # Number of cells to aggregate per bin when generate an aggregated input CDS for cicero
                     coords=dcluster_coords, # A data frame with columns representing the coordinates of each cell in reduced dimension space (generally 2-3 dimensions). 
                     genome='macFas5' # reference genome, must be one of "hg19", "mm10", or "hg38"
){
  # check genome
  if (!genome %in% c("hg19", "hg38", "mm10", "macFas5"))
    stop("You must specify one of hg19, hg38, mm10, macFas5 as a genome build for currently supported TSS annotations..\n")
  
  indata <- peaks.mat[unique(unlist(GPPair)),]
  # binarize the matrix
  indata@x[indata@x > 0] <- 1
  # format peak info
  peakinfo <- as.data.frame(rownames(indata))
  rownames(peakinfo) <- peakinfo[,1]
  names(peakinfo) <- "site_name"
  
  input_cds <- suppressWarnings(new_cell_data_set(indata, cell_metadata = cellinfo, gene_metadata = peakinfo))
  input_cds <- monocle3::detect_genes(input_cds)
  
  #Ensure there are no peaks included with zero reads
  input_cds <- input_cds[Matrix::rowSums(exprs(input_cds)) != 0,] 
  
  ###Create a Cicero CDS
  cicero_cds <- make_cicero_cds(input_cds, reduced_coordinates = dcluster_coords, k = k) 
  
  ###Run Cicero
  chromsize <- read.delim(file=paste0('../data/',genome,'.chrom.sizes'), skip=0, header=F, check.names = FALSE,sep = "\t",stringsAsFactors = FALSE)
  
  conns <- run_cicero(cicero_cds, chromsize) 
  
  #############################
  # OUTPUT
  return(conns)
}





# ------------------ This step is to build the enhancer network for each gene
############## INPUT: 1. A data frame of co-accessibility scores; 2. a list of enhancer cluster
############## OUTPUT: .pdf files, will be saved under a new created folder ./plot/
############## For determining a threshold value of coaccessibility, we advice to choose the value around quantile 90%-95% of 
BuildNetwork <- function(conns=conns, # A data frame of co-accessibility scores, also the output of Step.3
                         GPTab=GPTabFilt,  # A data frame of filtered significantly correlated peak-gene pairs generated in Step.2
                         cutoff=0.1, # The cutoff of co-accessibility score to determine whether the enhancer pairs are significantly co-accessible.
                         nCores=8 # How many registerCores to use
){
    conns <- conns %>% filter(coaccess >= cutoff)
    conns$Peak1 <- as.character(conns$Peak1)
    conns$Peak2 <- as.character(conns$Peak2)
    
    #---
    genes <- unique(GPTab$Gene)
    
    future::plan("multicore", workers = as.numeric(nCores))
    NetworkList <- pbapply::pblapply(genes, function(g) {
        # Filter the GPTab for the current gene
        GPTabFilt_g <- GPTab %>% filter(Gene == g)
        # Create the network for the gene
        eNet <- Network(conns = conns, GPTab = GPTabFilt_g, cutoff = cutoff)
        
        return(eNet)
    }, cl = "future")
    names(NetworkList) <- genes
    NetworkList <- Filter(Negate(is.null), NetworkList)
  
    return(NetworkList)
}



# ------------------ This step is to calculate network size and network connectivity
############## INPUT: A data frame of Cicero co-accessibility scores; 2. a list of enhancer cluster
############## OUTPUT: A data frame with 3 columns, including gene, NetworkSize and NetworkConnectivity
NetComplexity <- function(conns=conns, # A data frame of co-accessibility scores, also the output of Step.3
                          GPTab=GPTabFilt,  # A list of enhancer cluster, the output of Step.2
                          cutoff=0.2, # The cutoff of co-accessibility score to determine whether the enhancer pairs are significantly co-accessible.
                          nCores=8 # How many registerCores to use
){
    
    for (pkg in c("igraph","dplyr","pbapply")){library(pkg, character.only = TRUE)}
    
    conns <- conns %>% filter(coaccess >= cutoff)
    conns$Peak1 <- as.character(conns$Peak1)
    conns$Peak2 <- as.character(conns$Peak2)
    
    #---
    genes <- unique(GPTab$Gene)
    #---
    ####
    future::plan("multicore", workers = as.numeric(nCores))
    Networkinfo <- pblapply(genes, function(g) {
        GPTabFilt_g <- GPTab %>% filter(Gene == g)
        return({
            NetworkComplexity(net = NetworkList[[g]],gene = g,GPTab = GPTabFilt_g)
        })
        
    }, cl = "future") %>% bind_rows()

    return({
        Networkinfo
    })
}


# ------------------ This step is to classify enhancer networks into three mode, including Complex, Multiple and Simple based on network size and network connectivity
############## INPUT: 1. A data frame with 3 columns, including gene, NetworkSize, NetworkConnectivity
############## OUTPUT: A data frame with 4 columns, including gene, NetworkSize, NetworkConnectivity and Mode
NetworkMode <- function(Networkinfo=Networkinfo,  # Networkinfo is the output file in Step.5
                        SizeCutoff=5, # The threshold value of network size, which can be used to distinguish Simple and Complex/Multiple mode
                        ConnectivityCutoff=1 # The threshold value of network connectivity, which can be used to distinguish Complex and Multiple mode
){
  Networkinfo$NetworkSize <- log2(Networkinfo$NetworkSize)
  Networkinfo$Mode <- NA
  Networkinfo[which(Networkinfo$NetworkSize>log2(SizeCutoff) & Networkinfo$NetworkConnectivity>=ConnectivityCutoff),]$Mode <- 'Complex'
  Networkinfo[which(Networkinfo$NetworkSize>log2(SizeCutoff) & Networkinfo$NetworkConnectivity<ConnectivityCutoff),]$Mode <- 'Multiple'
  Networkinfo[which(Networkinfo$NetworkSize<=log2(SizeCutoff)),]$Mode <- 'Simple'
  Networkinfo$Mode <- factor(Networkinfo$Mode, levels = c('Complex','Multiple','Simple'))
  
  Networkinfo <- Networkinfo[order(Networkinfo$NetworkConnectivity, decreasing = T),]
  Mode <- Networkinfo  
  Networkinfo$label <- NA
  Networkinfo[1:20,]$label <- rownames(Networkinfo[1:20,])
  
  Mode$NetworkSize <- round(2^(Mode$NetworkSize))
  #############################
  # OUTPUT
  return(Mode)
}


# ------------------ This step is to generate the umap embedding for CRE peak-matrix
  GetHarmonyUMAP <- function(cre.mat, batch = NULL, return_img = FALSE){
    signacObj <- CreateSeuratObject(counts = cre.mat)
    signacObj$batch <- as.vector(batch)
    # normalization, feature selection, dim reduction #
    {
      signacObj <- signacObj %>% RunTFIDF(verbose = F) %>% 
        FindTopFeatures(verbose = F) %>% RunSVD(verbose = F) 
      if (!is.null(batch)) {
        signacObj <- signacObj %>% 
          harmony::RunHarmony( group.by.vars = "batch", reduction.use = 'lsi', project.dim = F,verbose = F) %>% 
          RunUMAP(reduction = 'harmony', dims = 2:25,verbose = F) 
      }else{
        signacObj <- signacObj %>% RunUMAP(reduction = 'lsi', dims = 2:25,verbose = F) 
      }
      
      if (return_img) {
        umap_plot <- DimPlot(signacObj,group.by = "batch",label = T)
        ggplot2::ggsave("dcluster_coords.jpg", plot = umap_plot)
      }
    }
    
    umap_coords <- Embeddings(signacObj, reduction = "umap") %>% data.frame %>% setNames(c("UMAP_1","UMAP_2"))
    return( umap_coords )
  }



