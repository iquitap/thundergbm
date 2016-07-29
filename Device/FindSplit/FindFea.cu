/*
 * DeviceSplitter.cu
 *
 *  Created on: 5 May 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#include <iostream>

#include "../../DeviceHost/MyAssert.h"
#include "../../DeviceHost/svm-shared/HostUtility.h"
#include "../KernelConf.h"
#include "../Hashing.h"
#include "../Splitter/DeviceSplitter.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../Memory/findFeaMemManager.h"
#include "../Memory/SNMemManager.h"
#include "FindFeaKernel.h"
#include "IndexComputer.h"

using std::cout;
using std::endl;
using std::make_pair;
using std::cerr;

#ifdef testing
#undef testing
#endif

/**
 * @brief: efficient best feature finder
 */
void DeviceSplitter::FeaFinderAllNode(vector<SplitPoint> &vBest, vector<nodeStat> &rchildStat, vector<nodeStat> &lchildStat)
{
	GBDTGPUMemManager manager;
	SNGPUManager snManager;
	int numofSNode = manager.m_curNumofSplitable;
	int maxNumofSplittable = manager.m_maxNumofSplittable;
	int nNumofFeature = manager.m_numofFea;
	PROCESS_ERROR(nNumofFeature > 0);

	FFMemManager ffManager;
	ffManager.resetMemForFindFea();

	//process in a few rounds each of which has a subset of splittable nodes
#if testing
	int numRound = Ceil(numofSNode, ffManager.maxNumofSNodeInFF);
	if(numRound > 1)
		cout << "FindFea in " << numRound << " rounds." << endl;

	SplitPoint *testBestSplitPoint1 = new SplitPoint[maxNumofSplittable];
	nodeStat *testpRChildStat = new nodeStat[maxNumofSplittable];
	nodeStat *testpLChildStat = new nodeStat[maxNumofSplittable];
	SplitPoint *testBestSplitPoint3 = new SplitPoint[maxNumofSplittable];
	nodeStat *testpRChildStat3 = new nodeStat[maxNumofSplittable];
	nodeStat *testpLChildStat3 = new nodeStat[maxNumofSplittable];
#endif

	//compute index for each feature value
	int *pBuffIdVec_h = new int[numofSNode];//all splittable node buffer index should be copied
	int *pSNIdToBuffId_h = new int[maxNumofSplittable];
	clock_t comIdx_start = clock();
	manager.MemcpyDeviceToHost(manager.m_pBuffIdVec, pBuffIdVec_h, sizeof(int) * numofSNode);
	manager.MemcpyDeviceToHost(manager.m_pSNIdToBuffId, pSNIdToBuffId_h, sizeof(int) * maxNumofSplittable);
	IndexComputer indexComp;
	manager.MemcpyDeviceToHost(manager.m_pInsIdToNodeId, indexComp.m_insIdToNodeId_dh, sizeof(int) * manager.m_numofIns);
	//compute indices
	indexComp.ComputeIndex(numofSNode, pSNIdToBuffId_h, maxNumofSplittable, pBuffIdVec_h);
	clock_t comIdx_end = clock();
	total_com_idx_t += (comIdx_end - comIdx_start);
	//copy index info to device memory
	manager.MemcpyHostToDevice(indexComp.m_pIndices_dh, ffManager.m_pIndices_d, sizeof(int) * ffManager.m_totalNumFeaValue);
	manager.MemcpyHostToDevice(indexComp.m_pNumFeaValueEachNode_dh, ffManager.m_pNumFeaValueEachNode_d, sizeof(int) * maxNumofSplittable);
	manager.MemcpyHostToDevice(indexComp.m_pFeaValueStartPosEachNode_dh, ffManager.m_pFeaValueStartPosEachNode_d, sizeof(int) * maxNumofSplittable);
	manager.MemcpyHostToDevice(indexComp.m_pEachFeaStartPosEachNode_dh, ffManager.m_pEachFeaStartPosEachNode_d, sizeof(int) * maxNumofSplittable * nNumofFeature);
	manager.MemcpyHostToDevice(indexComp.m_pEachFeaLenEachNode_dh, ffManager.m_pEachFeaLenEachNode_d, sizeof(int) * maxNumofSplittable * nNumofFeature);

	//load gd and hessian to a dense array in device memory
//	cout << "load gd" << endl;
	KernelConf conf;
	int blockSizeLoadGD;
	dim3 dimNumofBlockToLoadGD;
	conf.ConfKernel(indexComp.m_totalFeaValue, blockSizeLoadGD, dimNumofBlockToLoadGD);
	clock_t start_gd = clock();
	LoadGDHessFvalue<<<dimNumofBlockToLoadGD, blockSizeLoadGD>>>(manager.m_pGrad, manager.m_pHess, manager.m_numofIns,
														   manager.m_pDInsId, manager.m_pdDFeaValue, ffManager.m_pIndices_d, indexComp.m_totalFeaValue,
														   ffManager.pGDEachFeaValue, ffManager.pHessEachFeaValue, ffManager.pDenseFeaValue);
	cudaDeviceSynchronize();
	clock_t end_gd = clock();
	total_fill_gd_t += (end_gd - start_gd);
	manager.MemcpyDeviceToHost(ffManager.pGDEachFeaValue, ffManager.pGDPrefixSum, sizeof(float_point) * manager.m_totalNumofValues);
	manager.MemcpyDeviceToHost(ffManager.pHessEachFeaValue, ffManager.pHessPrefixSum, sizeof(float_point) * manager.m_totalNumofValues);

#if true
	float_point deltaTest = 0.01;
	float_point *pfGDEachFeaValue_h = new float_point[manager.m_totalNumofValues];
	float_point *pfHessEachFeaValue_h = new float_point[manager.m_totalNumofValues];
	manager.MemcpyDeviceToHost(ffManager.pGDEachFeaValue, pfGDEachFeaValue_h, sizeof(float_point) * manager.m_totalNumofValues);
	manager.MemcpyDeviceToHost(ffManager.pHessEachFeaValue, pfHessEachFeaValue_h, sizeof(float_point) * manager.m_totalNumofValues);
#endif

//	cout << "prefix sum" << endl;
	clock_t start_scan = clock();
	//compute prefix sum for gd and hess
	PrefixSumForEachNode(indexComp.m_numFea * numofSNode, ffManager.pGDPrefixSum, ffManager.pHessPrefixSum,
						 ffManager.m_pEachFeaStartPosEachNode_d, indexComp.m_pEachFeaLenEachNode_dh);//last parameter is a host variable
	cudaDeviceSynchronize();
	clock_t end_scan = clock();
	total_scan_t += (end_scan - start_scan);

#if true
	float_point *pfGDScanEachFeaValue_h = new float_point[manager.m_totalNumofValues];
	float_point *pfHessScanEachFeaValue_h = new float_point[manager.m_totalNumofValues];
	manager.MemcpyDeviceToHost(ffManager.pGDPrefixSum, pfGDScanEachFeaValue_h, sizeof(float_point) * manager.m_totalNumofValues);
	manager.MemcpyDeviceToHost(ffManager.pHessPrefixSum, pfHessScanEachFeaValue_h, sizeof(float_point) * manager.m_totalNumofValues);
	for(int n = 0; n < numofSNode; n++)
	{
		for(int fid = 0; fid < manager.m_numofFea; fid++)
		{
			float_point fGDScan = 0;
			float_point fHessScan = 0;
			int nodeStartPos = indexComp.m_pEachFeaStartPosEachNode_dh[n * manager.m_numofFea + fid];
			for(int fv = 0; fv < indexComp.m_pEachFeaLenEachNode_dh[n * manager.m_numofFea + fid]; fv++)
			{
				int pos = nodeStartPos + fv;
				fGDScan += pfGDEachFeaValue_h[pos];
				fHessScan += pfHessEachFeaValue_h[pos];
				if(abs(pfGDScanEachFeaValue_h[pos] - fGDScan) > deltaTest)
				{
					cout << "scan gd diff " << pfGDScanEachFeaValue_h[pos] << " v.s. " << fGDScan << endl;
				}
				if(abs(pfHessScanEachFeaValue_h[pos] - fHessScan) > deltaTest)
				{
					cout << "scan hess diff " << pfHessScanEachFeaValue_h[pos] << " v.s. " << fHessScan << endl;
				}
			}
		}
	}
#endif


//	cout << "compute gain" << endl;
	clock_t start_comp_gain = clock();
	//compute gain
	int numofDenseValue = indexComp.m_pFeaValueStartPosEachNode_dh[numofSNode - 1] + indexComp.m_pNumFeaValueEachNode_dh[numofSNode - 1];
	int blockSizeComGain;
	dim3 dimNumofBlockToComGain;
	conf.ConfKernel(numofDenseValue, blockSizeComGain, dimNumofBlockToComGain);
	ComputeGainDense<<<dimNumofBlockToComGain, blockSizeComGain>>>(
											manager.m_pSNodeStat, ffManager.m_pFeaValueStartPosEachNode_d, numofSNode,
											manager.m_pBuffIdVec,
											DeviceSplitter::m_lambda, ffManager.pGDPrefixSum, ffManager.pHessPrefixSum,
											ffManager.pDenseFeaValue, numofDenseValue, ffManager.pGainEachFeaValue);
	cudaDeviceSynchronize();

#if true
	float_point *pGainDense = new float_point[manager.m_totalNumofValues];
	memset(pGainDense, 0, sizeof(float_point) * manager.m_totalNumofValues);
	manager.MemcpyDeviceToHost(ffManager.pGainEachFeaValue, pGainDense, sizeof(float_point) * manager.m_totalNumofValues);
	float_point maxGain = -1;
	int max_id = -1;
	for(int i = 0; i < manager.m_totalNumofValues; i++)
	{//find the max gain
		if(pGainDense[i] > maxGain)
		{
			maxGain = pGainDense[i];
			max_id = i;
		}
	}
	cout << "max gain before fixing is " << maxGain << " id = " << max_id << endl;
#endif

//	cout << "first fea gain removal" << endl;
	//change the gain of the first feature value to 0
	int numFeaStartPos = indexComp.m_numFea * numofSNode;
	int blockSizeFirstGain;
	dim3 dimNumofBlockFirstGain;
	conf.ConfKernel(numFeaStartPos, blockSizeFirstGain, dimNumofBlockFirstGain);
	FirstFeaGain<<<dimNumofBlockFirstGain, blockSizeFirstGain>>>(ffManager.m_pEachFeaStartPosEachNode_d, numFeaStartPos, ffManager.pGainEachFeaValue);
	cudaDeviceSynchronize();
	clock_t end_comp_gain = clock();
	total_com_gain_t += (end_comp_gain - start_comp_gain);
#if true
	manager.MemcpyDeviceToHost(ffManager.pGainEachFeaValue, pGainDense, sizeof(float_point) * manager.m_totalNumofValues);
	maxGain = -1;
	for(int i = 0; i < manager.m_totalNumofValues; i++)
	{//find the max gain
		if(pGainDense[i] > maxGain)
			maxGain = pGainDense[i];
	}
	cout << "max gain after fixing is " << maxGain << endl;
	delete []pGainDense;
#endif

//	cout << "searching" << endl;
	clock_t start_search = clock();
	//find the block level best gain for each node
	int maxNumFeaValueOneNode = -1;
	for(int n = 0; n < numofSNode; n++)
	{//find the node with the max number of element
		if(maxNumFeaValueOneNode < indexComp.m_pNumFeaValueEachNode_dh[n])
			maxNumFeaValueOneNode = indexComp.m_pNumFeaValueEachNode_dh[n];
	}
	PROCESS_ERROR(maxNumFeaValueOneNode > 0);
	int blockSizeLocalBestGain;
	dim3 dimNumofBlockLocalBestGain;
	conf.ConfKernel(maxNumFeaValueOneNode, blockSizeLocalBestGain, dimNumofBlockLocalBestGain);
	PROCESS_ERROR(dimNumofBlockLocalBestGain.z == 1);
	dimNumofBlockLocalBestGain.z = numofSNode;//each node per super block
	int numBlockPerNode = dimNumofBlockLocalBestGain.x * dimNumofBlockLocalBestGain.y;
	PickLocalBestSplitEachNode<<<dimNumofBlockLocalBestGain, blockSizeLocalBestGain>>>(
								ffManager.m_pNumFeaValueEachNode_d, ffManager.m_pFeaValueStartPosEachNode_d,
								ffManager.pGainEachFeaValue, ffManager.pfLocalBestGain_d, ffManager.pnLocalBestGainKey_d);
	cudaDeviceSynchronize();

	//find the global best gain for each node
	if(numBlockPerNode > 1)
	{
		int blockSizeBestGain;
		dim3 dimNumofBlockDummy;
		conf.ConfKernel(numBlockPerNode, blockSizeBestGain, dimNumofBlockDummy);
		PickGlobalBestSplitEachNode<<<numofSNode, blockSizeBestGain>>>(
									ffManager.pfLocalBestGain_d, ffManager.pnLocalBestGainKey_d,
									ffManager.pfGlobalBestGain_d, ffManager.pnGlobalBestGainKey_d,
								    numBlockPerNode, numofSNode);
		cudaDeviceSynchronize();
	}
	else
	{//local best fea is the global best fea
		manager.MemcpyDeviceToDevice(ffManager.pfLocalBestGain_d, ffManager.pfGlobalBestGain_d, sizeof(float_point) * numofSNode);
		manager.MemcpyDeviceToDevice(ffManager.pnLocalBestGainKey_d, ffManager.pnGlobalBestGainKey_d, sizeof(int) * numofSNode);
	}

	cudaDeviceSynchronize();
	clock_t end_search = clock();
	total_search_t += end_search - start_search;

//	cout << "construct split point" << endl;
	//construct split points
	manager.MemcpyHostToDevice(manager.m_pBestPointHost, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);
	FindSplitInfo<<<1, numofSNode>>>(ffManager.m_pEachFeaStartPosEachNode_d, ffManager.m_pEachFeaLenEachNode_d,
				  	  	  	  	  	 ffManager.pDenseFeaValue, ffManager.pfGlobalBestGain_d, ffManager.pnGlobalBestGainKey_d,
				  	  	  	  	  	 manager.m_pBuffIdVec, nNumofFeature,
				  	  	  	  	  	 manager.m_pSNodeStat, ffManager.pGDPrefixSum, ffManager.pHessPrefixSum,
				  	  	  	  	  	 manager.m_pBestSplitPoint, manager.m_pRChildStat, manager.m_pLChildStat);
	cudaDeviceSynchronize();
//	cout << "Done find split" << endl;

#if testing
	manager.MemcpyDeviceToHost(manager.m_pBestSplitPoint, testBestSplitPoint3, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pRChildStat, testpRChildStat3, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pLChildStat, testpLChildStat3, sizeof(nodeStat) * maxNumofSplittable);
//#endif
	//end using dense array

	//start find split points
	for(int r = 0; r < numRound; r++)
	{
		ffManager.resetMemForFindFea();

		//get the splittable node batch information
		int numNodeInProgress = ffManager.maxNumofSNodeInFF;
		if((r + 1) * ffManager.maxNumofSNodeInFF > numofSNode)
			numNodeInProgress = numofSNode - r * ffManager.maxNumofSNodeInFF;
		int smallestNodeId = r * ffManager.maxNumofSNodeInFF;
		cout << "numof node in progress is " << numNodeInProgress << "; start node id is " << smallestNodeId << endl;

		int smallestFeaId = 0;//######### need to change to handle datasets with a large number of features
		int feaBatch = nNumofFeature;//find best splits for a subset of features
		int maxNumofValuePerFea = manager.m_numofIns;//maximum number of instances that have non-zero value at the feature
		long long totalEleInWholeBatch = manager.m_totalNumofValues * numNodeInProgress;//######### use all the features

		//kernel configuration
		int blockSizeFillGD;
		dim3 dimNumofBlockToFillGD;
		conf.ConfKernel(maxNumofValuePerFea, blockSizeFillGD, dimNumofBlockToFillGD);
		PROCESS_ERROR(dimNumofBlockToFillGD.y == 1 && dimNumofBlockToFillGD.z == 1);//must be one dimensional block
		int numofBlockFillGD = dimNumofBlockToFillGD.x;
		dim3 dimGrid(numofBlockFillGD, feaBatch, numNodeInProgress);
		dim3 dimBlock(blockSizeFillGD, 1, 1);

		clock_t start_gd = clock();

		//get gd for every splittable node
		ObtainGDEachNode<<<dimGrid, dimBlock>>>(manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, manager.m_pDInsId,
												manager.m_pdDFeaValue, manager.m_pInsIdToNodeId,
												manager.m_pGrad, manager.m_pHess, manager.m_pBuffIdVec, manager.m_pSNIdToBuffId,
												maxNumofSplittable, numNodeInProgress, smallestNodeId, smallestFeaId, nNumofFeature, feaBatch,
												ffManager.m_pGDOnEachFeaValue_d, ffManager.m_pHessOnEachFeaValue_d, ffManager.m_pValueOnEachFeaValue_d);
		cudaDeviceSynchronize();
		clock_t end_gd = clock();
		total_fill_gd_t += (end_gd - start_gd);

//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in ObtainGDEachNode" << endl;
		exit(0);
	}

	//nid, buffer id, snid relationships
	int *pInsToNodeId_h = new int[manager.m_numofIns];
	manager.MemcpyDeviceToHost(manager.m_pInsIdToNodeId, pInsToNodeId_h, sizeof(int) * manager.m_numofIns);

	//gd/hess for each fea value
	float_point *pGDOnEachFeaVaue_h = new float_point[totalEleInWholeBatch];
	float_point *pHessOnEachFeaValue_h = new float_point[totalEleInWholeBatch];
	manager.MemcpyDeviceToHost(ffManager.m_pGDOnEachFeaValue_d, pGDOnEachFeaVaue_h, sizeof(float_point) * totalEleInWholeBatch);
	manager.MemcpyDeviceToHost(ffManager.m_pHessOnEachFeaValue_d, pHessOnEachFeaValue_h, sizeof(float_point) * totalEleInWholeBatch);

	int *pnKeyValue = new int[nNumofFeature];
	long long *plFeaStartPos = new long long[nNumofFeature];
	int *pnInsId = new int[manager.m_totalNumofValues];
	float_point *pGrad = new float_point[manager.m_numofIns];

	manager.MemcpyDeviceToHost(manager.m_pDNumofKeyValue, pnKeyValue, sizeof(int) * nNumofFeature);
	manager.MemcpyDeviceToHost(manager.m_pFeaStartPos, plFeaStartPos, sizeof(long long) * nNumofFeature);
	manager.MemcpyDeviceToHost(manager.m_pDInsId, pnInsId, sizeof(int) * manager.m_totalNumofValues);
	manager.MemcpyDeviceToHost(manager.m_pGrad, pGrad, sizeof(float_point) * manager.m_numofIns);

	//get current fea batch size
	long long startPosOfSmallest = plFeaStartPos[smallestFeaId];
	int largestFeaId = smallestFeaId + feaBatch - 1;
	long long startPosOfLargest = plFeaStartPos[largestFeaId];
	int batchSize = startPosOfLargest - startPosOfSmallest + pnKeyValue[largestFeaId];

	int e = 0;
	for(int n = 0; n < numNodeInProgress; n++)//for each splittable node
	{
		int hashValue = pBuffIdVec_h[n + smallestNodeId];
		e = 0;
		for(int f = 0; f < nNumofFeature; f++)
		{
			int numofKeyValue = pnKeyValue[f];
			for(int i = 0; i < numofKeyValue; i++)
			{
				int insId = pnInsId[e];
				float_point gd = pGrad[insId];
				int nid = pInsToNodeId_h[insId];
				if(nid == -1)
					continue;

				int hashValue_buffer = Hashing::HostGetBufferId(pSNIdToBuffId_h, nid, maxNumofSplittable);
				if(pHessOnEachFeaValue_h[e + n * batchSize] != 0 && pHessOnEachFeaValue_h[e + n * batchSize] != 1)
				{
					cerr << "hess should be 1 or 0: " << pHessOnEachFeaValue_h[e + n * batchSize] << endl;
				}
				if(hashValue == hashValue_buffer)
				{
					if(pGDOnEachFeaVaue_h[e + n * batchSize] != gd || pHessOnEachFeaValue_h[e + n * batchSize] != 1)
						cerr << "hessian != 1: "<< pHessOnEachFeaValue_h[e + n * batchSize] << "; gd diff: "
							 << gd << " v.s. " << pGDOnEachFeaVaue_h[e + n * batchSize] << endl;
				}
				else
					if(pGDOnEachFeaVaue_h[e + n * batchSize] != 0 || pHessOnEachFeaValue_h[e + n * batchSize] != 0)
						cerr << "hessian != 0: "<< pHessOnEachFeaValue_h[e + n * batchSize] << "; gd diff: "
							 << gd << " v.s. " << pGDOnEachFeaVaue_h[e + n * batchSize] << endl;
				e++;
			}
		}
	}

	delete []pGrad;

	//compare with fill dense
	if(numofSNode == 1)
	{
		for(int i = 0; i < manager.m_totalNumofValues; i++)
		{
			if(pfGDEachFeaValue_h[i] != pGDOnEachFeaVaue_h[i])
			{
				cout << "gd diff " << pfGDEachFeaValue_h[i] << " v.s. " << pGDOnEachFeaVaue_h[i] << endl;
			}
			if(pfHessEachFeaValue_h[i] != pHessOnEachFeaValue_h[i])
			{
				cout << "hess diff " << pfHessEachFeaValue_h[i] << " v.s. " << pHessOnEachFeaValue_h[i] << endl;
			}
		}
	}
	delete []pfGDEachFeaValue_h;
	delete []pfHessEachFeaValue_h;

//#endif

	//each splittable node has its own copy of feature start pos and fea value length info, for calling the API of prefix sum
	int blockSizePosEachFeaInBatch;
	dim3 dimNumofBlockFindPosEachFeaInBatch;
	conf.ConfKernel(feaBatch, blockSizePosEachFeaInBatch, dimNumofBlockFindPosEachFeaInBatch);
	PROCESS_ERROR(dimNumofBlockFindPosEachFeaInBatch.z == 1 && dimNumofBlockFindPosEachFeaInBatch.y == 1);
	GetInfoEachFeaInBatch<<<dimNumofBlockFindPosEachFeaInBatch, blockSizePosEachFeaInBatch>>>(
												manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, smallestFeaId, nNumofFeature,
											    feaBatch, numNodeInProgress, smallestNodeId,
											    ffManager.m_pStartPosEachFeaInBatch_d, ffManager.m_pFeaLenInBatch_d);
	//############## Not very confident on the correctness of the above function, after adding smallestNodeId
	cudaDeviceSynchronize();
//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in GetInfoEachFeaInBatch" << endl;
		exit(0);
	}
	int *pStartPosEachFeaInBatch_h = new int[feaBatch * numNodeInProgress];
	int *pFeaLenInBatch_h = new int[feaBatch * numNodeInProgress];

	manager.MemcpyDeviceToHost(ffManager.m_pStartPosEachFeaInBatch_d, pStartPosEachFeaInBatch_h, sizeof(int) * feaBatch * numNodeInProgress);
	manager.MemcpyDeviceToHost(ffManager.m_pFeaLenInBatch_d, pFeaLenInBatch_h, sizeof(int) * feaBatch * numNodeInProgress);

	for(int n = 0; n < numNodeInProgress; n++)
	{
		for(int b = 0; b < feaBatch; b++)
		{
			int feaId = b + smallestFeaId;
			if(pStartPosEachFeaInBatch_h[b + n * feaBatch] - n * batchSize != plFeaStartPos[feaId])
			{
				cerr << "diff in start pos: " << pStartPosEachFeaInBatch_h[b + n * feaBatch] << " v.s. "
					 << plFeaStartPos[feaId] << "; feaId=" << feaId << endl;
			}
			if(pFeaLenInBatch_h[b + n * feaBatch] != pnKeyValue[feaId])
			{
				cerr << "diff in fea len: " << pFeaLenInBatch_h[b + n * feaBatch] << " v.s. " << pnKeyValue[feaId] << "; feaId=" << feaId << endl;
			}
		}
	}

	delete []pStartPosEachFeaInBatch_h;
	delete []pFeaLenInBatch_h;
//#endif

	//compute prefix sum
	manager.MemcpyDeviceToDevice(ffManager.m_pGDOnEachFeaValue_d, ffManager.m_pGDPrefixSum_d, sizeof(float_point) * totalEleInWholeBatch);
	manager.MemcpyDeviceToDevice(ffManager.m_pHessOnEachFeaValue_d, ffManager.m_pHessPrefixSum_d, sizeof(float_point) * totalEleInWholeBatch);

	manager.MemcpyDeviceToHost(ffManager.m_pFeaLenInBatch_d, ffManager.m_pnEachFeaLen_h, sizeof(int) * feaBatch * numNodeInProgress);

	clock_t start_scan = clock();
	PrefixSumForEachNode(feaBatch * numNodeInProgress, ffManager.m_pGDPrefixSum_d, ffManager.m_pHessPrefixSum_d,
						 ffManager.m_pStartPosEachFeaInBatch_d, ffManager.m_pnEachFeaLen_h);
	cudaDeviceSynchronize();
	clock_t end_scan = clock();
	total_scan_t += (end_scan - start_scan);

//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in PrefixSumForEachNode" << endl;
		exit(0);
	}

	float_point *pGDPrefixSumOnEachFeaValue_h = new float_point[totalEleInWholeBatch];
	float_point *pHessPrefixSumOnEachFeaValue_h = new float_point[totalEleInWholeBatch];
	manager.MemcpyDeviceToHost(ffManager.m_pGDPrefixSum_d, pGDPrefixSumOnEachFeaValue_h, sizeof(float_point) * totalEleInWholeBatch);
	manager.MemcpyDeviceToHost(ffManager.m_pHessPrefixSum_d, pHessPrefixSumOnEachFeaValue_h, sizeof(float_point) * totalEleInWholeBatch);


	for(int n = 0; n < numNodeInProgress; n++)
	{
		e = 0;
		for(int f = 0; f < nNumofFeature; f++)
		{
			int numofKeyValue = pnKeyValue[f];
			float_point prefixSumGD = 0;
			float_point prefixSumHess = 0;
			for(int i = 0; i < numofKeyValue; i++)
			{
				prefixSumGD += pGDOnEachFeaVaue_h[e + n * batchSize];
				prefixSumHess += pHessOnEachFeaValue_h[e + n * batchSize];
				if(
				   (abs(prefixSumGD - pGDPrefixSumOnEachFeaValue_h[e + n * batchSize]) > deltaTest * abs(prefixSumGD) &&
					abs(prefixSumGD - pGDPrefixSumOnEachFeaValue_h[e + n * batchSize]) > deltaTest)||
				   prefixSumHess != pHessPrefixSumOnEachFeaValue_h[e + n * batchSize])
					cerr << "hessian or gd diff: hess "<< prefixSumHess << " v.s. " << pHessPrefixSumOnEachFeaValue_h[e + n * batchSize]
						 << "; gd: " << prefixSumGD << " v.s. " << pGDPrefixSumOnEachFeaValue_h[e + n * batchSize] << endl;
				e++;
			}
		}
	}

	delete []pGDOnEachFeaVaue_h;
	delete []pHessOnEachFeaValue_h;
//#endif

	//compute gain
	clock_t start_comp_gain = clock();
	ComputeGain<<<dimGrid, dimBlock>>>(manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, manager.m_pSNodeStat, smallestFeaId, feaBatch,
									   manager.m_pBuffIdVec, numNodeInProgress, smallestNodeId, DeviceSplitter::m_lambda, ffManager.m_pGDPrefixSum_d,
									   ffManager.m_pHessPrefixSum_d, ffManager.m_pHessOnEachFeaValue_d,
									   manager.m_pdDFeaValue, ffManager.m_pGainOnEachFeaValue_d);
	cudaDeviceSynchronize();
	clock_t end_comp_gain = clock();
	total_com_gain_t += (end_comp_gain - start_comp_gain);

//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in ComputeGain" << endl;
		exit(0);
	}
	nodeStat *pSNodeStat_h = new nodeStat[maxNumofSplittable];
	float_point *pGainOnEachFeaValue_h = new float_point[totalEleInWholeBatch];
	manager.MemcpyDeviceToHost(manager.m_pSNodeStat, pSNodeStat_h, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(ffManager.m_pGainOnEachFeaValue_d, pGainOnEachFeaValue_h, sizeof(float_point) * totalEleInWholeBatch);

	e = 0;
	float_point *pFeaBestSplit = new float_point[feaBatch * numNodeInProgress];
	memset(pFeaBestSplit, 0, sizeof(float_point) * feaBatch * numNodeInProgress);
	for(int f = smallestFeaId; f < feaBatch + smallestFeaId; f++)
	{
		int numofKeyValue = pnKeyValue[f];
		int init = e;
		float_point prefixSumGD = 0;
		float_point prefixSumHess = 0;
		for(int i = init; i < numofKeyValue + init; i++)
		{
			int insId = pnInsId[i];
			int nid = pInsToNodeId_h[insId];
			if(nid == -1)
			{
				e++;
				continue;
			}

			for(int n = 0; n < numNodeInProgress; n++)
			{
				int hashValue_buffer = Hashing::HostGetBufferId(pSNIdToBuffId_h, nid, maxNumofSplittable);
				if(hashValue_buffer < 0)
					cerr << "hash value in host side is negative: " << hashValue_buffer << " for key " << nid << endl;
				int hashValue = pBuffIdVec_h[n + smallestNodeId];
				if(hashValue_buffer != hashValue)
					continue;

				float_point snGD = pSNodeStat_h[hashValue].sum_gd;
				float_point snHess = pSNodeStat_h[hashValue].sum_hess;
				float_point gainOnFeaValue;
				if(i == init)
				{
					gainOnFeaValue = 0;
				}
				else
				{
					int exclusiveSumPos = i + n * batchSize - 1;//follow xgboost using exlusive sum on gd and hess
					float_point tempGD = pGDPrefixSumOnEachFeaValue_h[exclusiveSumPos];
					float_point tempHess = pHessPrefixSumOnEachFeaValue_h[exclusiveSumPos];
					float_point fLChildGD = snGD - tempGD;
					float_point fLChildHess = snHess - tempHess;
					if(fLChildHess >= DeviceSplitter::min_child_weight && tempHess >= DeviceSplitter::min_child_weight)
					{
						gainOnFeaValue = (tempGD * tempGD)/(tempHess + DeviceSplitter::m_lambda) +
									 (fLChildGD * fLChildGD)/(fLChildHess + DeviceSplitter::m_lambda) -
									 (snGD * snGD)/(snHess + DeviceSplitter::m_lambda);
					}
					else
						gainOnFeaValue = 0;
				}
				if(abs(gainOnFeaValue - pGainOnEachFeaValue_h[i + n * batchSize]) > deltaTest)
				{
					cerr << "gain diff: "<< gainOnFeaValue << " v.s. " << pGainOnEachFeaValue_h[i + n * batchSize] << endl;
				}

				if(pFeaBestSplit[f + feaBatch * n] < gainOnFeaValue)
					pFeaBestSplit[f + feaBatch * n] = gainOnFeaValue;
			}
			e++;
		}
	}

	for(int n = smallestNodeId; n < numNodeInProgress + smallestNodeId; n++)
	{
		for(int f = 0; f < feaBatch; f++)
		{
//			cout << "local best before fixing for " << f << "th here is " << pFeaBestSplit[f + feaBatch * n] << endl;
		}
	}

	delete []pFeaBestSplit;

	delete []pInsToNodeId_h;
	delete []pnInsId;
	delete []pGDPrefixSumOnEachFeaValue_h;
	delete []pHessPrefixSumOnEachFeaValue_h;
//#endif

	//remove invalid gains. The same value can only have one gain
	clock_t start_fix_gain = clock();
	FixedGain<<<dimGrid, dimBlock>>>(manager.m_pDNumofKeyValue, manager.m_pFeaStartPos,  smallestFeaId, feaBatch,
									 numNodeInProgress, smallestNodeId,
									 ffManager.m_pHessOnEachFeaValue_d, manager.m_pdDFeaValue,
									 ffManager.m_pGainOnEachFeaValue_d, ffManager.m_pLastBiggerValue_d);
	cudaDeviceSynchronize();
	clock_t end_fix_gain = clock();
	total_fix_gain_t += (end_fix_gain - start_fix_gain);


//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in FixedGain" << endl;
		exit(0);
	}
//#endif

	clock_t start_search = clock();
	//find the local best split in this batch of features
	int nBlockEachFea = dimGrid.x;
	int nElePerBlock = dimBlock.x;
	PickFeaLocalBestSplit<<<dimGrid, dimBlock>>>(manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, ffManager.m_pGainOnEachFeaValue_d,
											  manager.m_pBuffIdVec, smallestFeaId, feaBatch,
											  numNodeInProgress, smallestNodeId, maxNumofSplittable,
											  ffManager.m_pfFeaLocalBestGain_d, ffManager.m_pnFeaLocalBestGainKey_d);
	cudaDeviceSynchronize();
//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in ComputeGain" << endl;
		exit(0);
	}

	float_point *pfFeaLocalBestGain_h = new float_point[feaBatch * nBlockEachFea * numNodeInProgress];
	int *pnFeaLocalBestGainKey_h = new int[feaBatch * nBlockEachFea * numNodeInProgress];
	manager.MemcpyDeviceToHost(ffManager.m_pfFeaLocalBestGain_d, pfFeaLocalBestGain_h, sizeof(float_point) * feaBatch * nBlockEachFea * numNodeInProgress);
	manager.MemcpyDeviceToHost(ffManager.m_pnFeaLocalBestGainKey_d, pnFeaLocalBestGainKey_h, sizeof(int) * feaBatch * nBlockEachFea * numNodeInProgress);

	float_point *pGlobalBest = new float_point[numNodeInProgress];
	float_point *pFeaBest = new float_point[numNodeInProgress * feaBatch];
	for(int n = 0; n < numNodeInProgress; n++)
	{
		pGlobalBest[n] = 100000;
		for(int f = 0; f < feaBatch; f++)
		{
			float_point localBest = 100000;
			for(int bl = 0; bl < nBlockEachFea; bl++)
			{
				float_point temp = pfFeaLocalBestGain_h[n * feaBatch * nBlockEachFea + f * nBlockEachFea + bl];
				if(localBest > temp)
					localBest = temp;
			}
//			cout << "local best for " << f << "th fea is " << localBest << " for node " << n << endl;
			if(pGlobalBest[n] > localBest)
				pGlobalBest[n] = localBest;
			pFeaBest[n * feaBatch + f] = localBest;
		}
	}

	//obtain the best for each node
	//use the fixed gain to compute the best gain
	manager.MemcpyDeviceToHost(ffManager.m_pGainOnEachFeaValue_d, pGainOnEachFeaValue_h, sizeof(float_point) * totalEleInWholeBatch);
	for(int n = 0; n < numNodeInProgress; n++)
	{
		float_point bestGain = -1000000;
		int key = -1;
		for(int i = 0; i < batchSize; i++)
		{
			if(bestGain < pGainOnEachFeaValue_h[i + n * batchSize])
			{
				bestGain = pGainOnEachFeaValue_h[i + n * batchSize];
				key = i;
			}
		}

		//compute feature id
		int bestFeaId = -1;
		int valuePos = -1;
		for(int f = 0; f < feaBatch; f++)
		{
			int numofKeyValue = pnKeyValue[f];
			if(plFeaStartPos[f] + numofKeyValue < key)
				continue;
			else
			{
				bestFeaId = f;
				valuePos = key - plFeaStartPos[f];
				break;
			}
		}
//		cout << "snid=" << n << "; best gain = " << bestGain << "; key is " << key << "; f=" << bestFeaId << "; value pos=" << valuePos << endl;
		if(-bestGain != pGlobalBest[n])
			cerr << "best gain diff: " << bestGain << " v.s. " << pGlobalBest[n] << endl;
	}

	delete []plFeaStartPos;
	delete []pGainOnEachFeaValue_h;
	delete []pnKeyValue;

	for(int n = 0; n < numNodeInProgress; n++)
	{
		float_point bestGain1 = 10000;
		int bestKey1 = -1;
		for(int i = 0; i < nBlockEachFea; i++)
		{
			if(bestGain1 > pfFeaLocalBestGain_h[i + n * nBlockEachFea])
			{
				bestGain1 = pfFeaLocalBestGain_h[i + n * nBlockEachFea];
				bestKey1 = pnFeaLocalBestGainKey_h[i + n * nBlockEachFea];
			}
		}
//		cout << "best gain = " << bestGain1 << "; best key = " << bestKey1 << endl;
	}

	delete []pfFeaLocalBestGain_h;
	delete []pnFeaLocalBestGainKey_h;
//#endif

	//find the best split for each feature in the batch
	int nThreadFeaBestBlock = nBlockEachFea;
	if(nThreadFeaBestBlock > conf.m_maxBlockSize)
		nThreadFeaBestBlock = conf.m_maxBlockSize;

	dim3 dimBlockSizeFeaBest(nThreadFeaBestBlock, 1, 1);
	dim3 dimGridFeaBest(1, feaBatch, numNodeInProgress);
	PickFeaGlobalBestSplit<<<dimGridFeaBest, dimBlockSizeFeaBest>>>(
							feaBatch, numNodeInProgress, ffManager.m_pfFeaLocalBestGain_d, ffManager.m_pnFeaLocalBestGainKey_d,
							ffManager.m_pfFeaGlobalBestGain_d, ffManager.m_pnFeaGlobalBestGainKey_d, nBlockEachFea);
	cudaDeviceSynchronize();
//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in ComputeGain" << endl;
		exit(0);
	}

	float_point *pfFeaGlobalBestGain_h = new float_point[feaBatch * numNodeInProgress];
	int *pnFeaGlobalBestGainKey_h = new int[feaBatch * numNodeInProgress];
	manager.MemcpyDeviceToHost(ffManager.m_pfFeaGlobalBestGain_d, pfFeaGlobalBestGain_h, sizeof(float_point) * feaBatch * numNodeInProgress);
	manager.MemcpyDeviceToHost(ffManager.m_pnFeaGlobalBestGainKey_d, pnFeaGlobalBestGainKey_h, sizeof(int) * feaBatch * numNodeInProgress);

	for(int n = 0; n < numNodeInProgress; n++)
	{
		for(int f = 0; f < feaBatch; f++)
		{
			if(pfFeaGlobalBestGain_h[f + n * feaBatch] != pFeaBest[f + n * feaBatch])
				cerr << "fea best diff: " << pfFeaGlobalBestGain_h[f + n * feaBatch]
				     << " v.s. " << pFeaBest[f + n * feaBatch] << "; snid = " << n << "; fid=" << f << endl;
		}
	}

	delete []pFeaBest;
	delete []pfFeaGlobalBestGain_h;
	delete []pnFeaGlobalBestGainKey_h;
//#endif

	//find the best feature
	//kernel configuration
	int blockSizeBestFeaBestSplit;
	dim3 tempNumofBlockBestFea;
	conf.ConfKernel(feaBatch, blockSizeBestFeaBestSplit, tempNumofBlockBestFea);
	int nBlockBestFea = tempNumofBlockBestFea.x;
	PROCESS_ERROR(tempNumofBlockBestFea.y == 1);
	dim3 dimBlockSizeBestFeaBestSplit(blockSizeBestFeaBestSplit, 1, 1);
	dim3 dimGridBestFeaBestSplit(nBlockBestFea, numNodeInProgress, 1);

	PickLocalBestFeaBestSplit<<<dimGridBestFeaBestSplit, dimBlockSizeBestFeaBestSplit>>>
											(feaBatch, numNodeInProgress, ffManager.m_pfFeaGlobalBestGain_d,
											 ffManager.m_pnFeaGlobalBestGainKey_d, ffManager.m_pfBlockBestFea_d, ffManager.m_pnBlockBestKey_d);
	cudaDeviceSynchronize();

//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in PickBestFeaBestSplit" << endl;
		exit(0);
	}

	float_point *pfBlockBestFea_h = new float_point[nBlockBestFea * numNodeInProgress];
	int *pnBlockBestKey_h = new int[nBlockBestFea * numNodeInProgress];
	manager.MemcpyDeviceToHost(ffManager.m_pfBlockBestFea_d, pfBlockBestFea_h, sizeof(float_point) * nBlockBestFea * numNodeInProgress);
	manager.MemcpyDeviceToHost(ffManager.m_pnBlockBestKey_d, pnBlockBestKey_h, sizeof(int) * nBlockBestFea * numNodeInProgress);

	for(int n = 0; n < numNodeInProgress; n++)
	{
		for(int f = 0; f < nBlockBestFea; f++)
		{
			if(pfBlockBestFea_h[n] != pGlobalBest[n] && nBlockBestFea == 1)
				cerr << "best gain diff: " << pfBlockBestFea_h[n] << " v.s. " << pGlobalBest[n] << endl;
		}
	}

	delete []pfBlockBestFea_h;
	delete []pnBlockBestKey_h;
//#endif

	if(nBlockBestFea > 1)
	{
		int threadPerBlockBestFea;
		dim3 dimNumofBlockBestFea;
		conf.ConfKernel(nBlockBestFea, threadPerBlockBestFea, dimNumofBlockBestFea);
		PROCESS_ERROR(dimNumofBlockBestFea.y == 1 && dimNumofBlockBestFea.z == 1 && dimNumofBlockBestFea.x == 1);
		dimNumofBlockBestFea.x = numNodeInProgress;
		PickGlobalBestFeaBestSplit<<<dimNumofBlockBestFea, threadPerBlockBestFea>>>(
													numNodeInProgress, nBlockBestFea, ffManager.m_pfBlockBestFea_d,
													ffManager.m_pnBlockBestKey_d, ffManager.m_pfGlobalBestFea_d, ffManager.m_pnGlobalBestKey_d);
		cudaDeviceSynchronize();
	}
	else
	{//local best fea is the global best fea
		manager.MemcpyDeviceToDevice(ffManager.m_pfBlockBestFea_d, ffManager.m_pfGlobalBestFea_d, sizeof(float_point) * numNodeInProgress);
		manager.MemcpyDeviceToDevice(ffManager.m_pnBlockBestKey_d, ffManager.m_pnGlobalBestKey_d, sizeof(int) * numNodeInProgress);
	}
	clock_t end_search = clock();
	total_search_t += end_search - start_search;

//#if testing
	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in PickGlobalBestFeaBestSplit" << endl;
		exit(0);
	}

	float_point *pfGlobalBestFea_h = new float_point[numNodeInProgress];
	int *pnGlobalBestKey_h = new int[numNodeInProgress];
	manager.MemcpyDeviceToHost(ffManager.m_pfGlobalBestFea_d, pfGlobalBestFea_h, sizeof(float_point) * numNodeInProgress);
	manager.MemcpyDeviceToHost(ffManager.m_pnGlobalBestKey_d, pnGlobalBestKey_h, sizeof(int) * numNodeInProgress);

	for(int n = 0; n < numNodeInProgress; n++)
	{

		if(pfGlobalBestFea_h[n] != pGlobalBest[n])
			cerr << "best gain diff: " << pfGlobalBestFea_h[n] << " v.s. " << pGlobalBest[n] << endl;
	}
	delete []pGlobalBest;
	delete []pnGlobalBestKey_h;
	delete []pfGlobalBestFea_h;
//#endif

	//get split point info

	//Memory set for best split points; may not be necessary now.
	manager.MemcpyHostToDevice(manager.m_pBestPointHost, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);

	FindSplitInfo<<<1, numNodeInProgress>>>(manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, manager.m_pdDFeaValue,
								  feaBatch, smallestFeaId, smallestNodeId,
								  ffManager.m_pfGlobalBestFea_d, ffManager.m_pnGlobalBestKey_d, manager.m_pBuffIdVec,
								  manager.m_pSNodeStat, ffManager.m_pGDPrefixSum_d, ffManager.m_pHessPrefixSum_d,
								  manager.m_pBestSplitPoint, manager.m_pRChildStat, manager.m_pLChildStat,
								  manager.m_pLastValue, ffManager.m_pGainOnEachFeaValue_d);
	cudaDeviceSynchronize();

//#if testing

	if(cudaGetLastError() != cudaSuccess)
	{
		cerr << "error in PickGlobalBestFeaBestSplit" << endl;
		exit(0);
	}

	int tempSN = 0;
	manager.MemcpyDeviceToHost(manager.m_pNumofBuffId, &tempSN, sizeof(int));
	PROCESS_ERROR(numofSNode == tempSN);
	//set memory
	int numofElement = nNumofFeature * manager.m_maxNumofSplittable;
	checkCudaErrors(cudaMemset(manager.m_pTempRChildStatPerThread, 0, sizeof(nodeStat) * numofElement));
	manager.MemcpyHostToDevice(manager.m_pBestPointHostPerThread, manager.m_pBestSplitPointPerThread, sizeof(SplitPoint) * numofElement);
		//optional memory set
	checkCudaErrors(cudaMemset(manager.m_pRChildStatPerThread, 0, sizeof(nodeStat) * numofElement));
	checkCudaErrors(cudaMemset(manager.m_pLChildStatPerThread, 0, sizeof(nodeStat) * numofElement));
	checkCudaErrors(cudaMemset(manager.m_pLastValuePerThread, -1, sizeof(float_point) * numofElement));

	manager.MemcpyDeviceToHost(manager.m_pBestSplitPoint, testBestSplitPoint1, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pRChildStat, testpRChildStat, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pLChildStat, testpLChildStat, sizeof(nodeStat) * maxNumofSplittable);

	for(int n = 0; n < numNodeInProgress; n++)
	{
		int buffId = pBuffIdVec_h[n + smallestNodeId];
		if(testBestSplitPoint1[buffId].m_fGain != 0)
		{
			if(pSNodeStat_h[buffId].sum_hess != testpRChildStat[buffId].sum_hess + testpLChildStat[buffId].sum_hess ||
			   abs(pSNodeStat_h[buffId].sum_gd - testpRChildStat[buffId].sum_gd - testpLChildStat[buffId].sum_gd) > deltaTest)
				cerr << "parent node stat != child node stats: "<< pSNodeStat_h[buffId].sum_hess
					 << " != " << testpRChildStat[buffId].sum_hess << "+" << testpLChildStat[buffId].sum_hess
					 << "; " << pSNodeStat_h[buffId].sum_gd
					 << " != " << testpRChildStat[buffId].sum_gd << "+" << testpLChildStat[buffId].sum_gd << endl;
		}
	}

	delete []pSNodeStat_h;
//#endif
	}//for each subset of splittable nodes

//#if testing
	int threadPerBlock;
	dim3 dimNumofBlock;
	conf.ConfKernel(nNumofFeature, threadPerBlock, dimNumofBlock);

	clock_t begin_per_fea, begin_best;
	clock_t end_per_fea, end_best;
	cudaDeviceSynchronize();
	begin_per_fea = clock();
	FindFeaSplitValue<<<dimNumofBlock, threadPerBlock>>>(
									  manager.m_pDNumofKeyValue, manager.m_pFeaStartPos, manager.m_pDInsId,
									  manager.m_pdDFeaValue, manager.m_pInsIdToNodeId,
									  manager.m_pGrad, manager.m_pHess,
									  manager.m_pTempRChildStatPerThread, manager.m_pLastValuePerThread,
									  manager.m_pSNodeStat, manager.m_pBestSplitPointPerThread,
									  manager.m_pRChildStatPerThread, manager.m_pLChildStatPerThread,
									  manager.m_pSNIdToBuffId, maxNumofSplittable, manager.m_pBuffIdVec, numofSNode,
									  DeviceSplitter::m_lambda, nNumofFeature);
	cudaDeviceSynchronize();
	end_per_fea = clock();
	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in FindFeaSplitValue" << endl;
		exit(0);
	}


	float_point *pfBestGain;
	int *pnBestGainKey;
	int threadPerBlockFindBest;
	dim3 dimNumofBlockFindBest;
	conf.ConfKernel(nNumofFeature, threadPerBlockFindBest, dimNumofBlockFindBest);
	PROCESS_ERROR(dimNumofBlockFindBest.y == 1);
	dimNumofBlockFindBest.y = numofSNode;
//	cout << "numof local best block is x=" << dimNumofBlockFindBest.x << " y=" << dimNumofBlockFindBest.y << endl;
	int numofBlockLocalBest = dimNumofBlockFindBest.x * dimNumofBlockFindBest.y;
	int numofBlockPerNode = dimNumofBlockFindBest.x;
	checkCudaErrors(cudaMalloc((void**)&pfBestGain, sizeof(float_point) * maxNumofSplittable * numofBlockLocalBest));
	checkCudaErrors(cudaMalloc((void**)&pnBestGainKey, sizeof(int) * maxNumofSplittable * numofBlockLocalBest));
	PickLocalBestFea<<<dimNumofBlockFindBest, threadPerBlockFindBest>>>(
					 manager.m_pBestSplitPointPerThread, manager.m_pBuffIdVec, numofSNode, nNumofFeature,
					 maxNumofSplittable, pfBestGain, pnBestGainKey);
	cudaDeviceSynchronize();

	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in PickLocalBestFea" << endl;
		exit(0);
	}


	int blockSizeBestFea = numofBlockPerNode;
	if(blockSizeBestFea > conf.m_maxBlockSize)
		blockSizeBestFea = conf.m_maxBlockSize;

	PickGlobalBestFea<<<numofSNode, blockSizeBestFea>>>(manager.m_pLastValuePerThread,
					  manager.m_pBestSplitPointPerThread, manager.m_pRChildStatPerThread, manager.m_pLChildStatPerThread,
					  manager.m_pBuffIdVec, numofSNode, pfBestGain, pnBestGainKey, numofBlockPerNode);

	if(cudaGetLastError() != cudaSuccess)
	{
		cout << "error in PickGlobalBestFea" << endl;
		exit(0);
	}


	//Memory set for best split points; may not be necessary now.
	manager.MemcpyHostToDevice(manager.m_pBestPointHost, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pBestSplitPointPerThread, manager.m_pBestSplitPoint, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pLastValuePerThread, manager.m_pLastValue, sizeof(float_point) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pRChildStatPerThread, manager.m_pRChildStat, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToDevice(manager.m_pLChildStatPerThread, manager.m_pLChildStat, sizeof(nodeStat) * maxNumofSplittable);


	//print best split points
	SplitPoint *testBestSplitPoint2 = new SplitPoint[maxNumofSplittable];
	nodeStat *testpRChildStat2 = new nodeStat[maxNumofSplittable];
	nodeStat *testpLChildStat2 = new nodeStat[maxNumofSplittable];
	manager.MemcpyDeviceToHost(manager.m_pBestSplitPoint, testBestSplitPoint2, sizeof(SplitPoint) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pRChildStat, testpRChildStat2, sizeof(nodeStat) * maxNumofSplittable);
	manager.MemcpyDeviceToHost(manager.m_pLChildStat, testpLChildStat2, sizeof(nodeStat) * maxNumofSplittable);

	//dense array
	float_point *pBestGainEachNode_h = new float_point[maxNumofSplittable];
	manager.MemcpyDeviceToHost(ffManager.pfGlobalBestGain_d, pBestGainEachNode_h, sizeof(float_point) * maxNumofSplittable);
	for(int sn = 0; sn < numofSNode; sn++)
	{
		int buffId = pBuffIdVec_h[sn];
		int posId = indexComp.m_pBuffIdToPos_dh[buffId];
		if(testBestSplitPoint1[buffId].m_fGain != pBestGainEachNode_h[posId])
			cout << testBestSplitPoint1[buffId].m_fGain << " v.s. " << pBestGainEachNode_h[posId] << endl;
	}

	//compare dense array and 1
	for(int sn = 0; sn < maxNumofSplittable; sn++)
	{
		int buffId = sn;//pBuffIdVec_h[sn];
		if(testBestSplitPoint1[buffId].m_nFeatureId != -1 && testBestSplitPoint3[buffId].m_nFeatureId != -1)
		{
		if(testBestSplitPoint1[buffId].m_nFeatureId != testBestSplitPoint3[buffId].m_nFeatureId ||
		   abs(testBestSplitPoint1[buffId].m_fGain - testBestSplitPoint3[buffId].m_fGain) > deltaTest ||
		   abs(testBestSplitPoint1[buffId].m_fSplitValue - testBestSplitPoint3[buffId].m_fSplitValue) > deltaTest ||
		   abs(testpRChildStat[buffId].sum_gd - testpRChildStat3[buffId].sum_gd) > deltaTest ||
		   testpRChildStat[buffId].sum_hess != testpRChildStat3[buffId].sum_hess ||
		   abs(testpLChildStat[buffId].sum_gd - testpLChildStat3[buffId].sum_gd) > deltaTest ||
		   testpLChildStat[buffId].sum_hess != testpLChildStat3[buffId].sum_hess)
			cerr << "final result diff: " << testBestSplitPoint1[buffId].m_nFeatureId << " v.s. " << testBestSplitPoint3[buffId].m_nFeatureId
				 << "; " << testBestSplitPoint1[buffId].m_fGain << " v.s. " << testBestSplitPoint3[buffId].m_fGain
				 << "; " << testBestSplitPoint1[buffId].m_fSplitValue << " v.s. " << testBestSplitPoint3[buffId].m_fSplitValue
				 << "; r gd: " << testpRChildStat[buffId].sum_gd << " v.s. " << testpRChildStat3[buffId].sum_gd
				 << "; r hess: " << testpRChildStat[buffId].sum_hess << " v.s. " << testpRChildStat3[buffId].sum_hess
				 << "; l gd: " << testpLChildStat[buffId].sum_gd << " v.s. " << testpLChildStat3[buffId].sum_gd
				 << "; l hess: " << testpLChildStat[buffId].sum_hess << " v.s. " << testpLChildStat3[buffId].sum_hess
				 << endl;
		}


//		cout << "nid=" << pTestBuffIdVect[sn] << "; snid=" << sn << "; gain=" << testBestSplitPoint[pTestBuffIdVect[sn]].m_fGain << "; fid="
//			 << testBestSplitPoint[pTestBuffIdVect[sn]].m_nFeatureId << "; sv=" << testBestSplitPoint[pTestBuffIdVect[sn]].m_fSplitValue << endl;
	}

	//compare 1 and 2
	for(int sn = 0; sn < maxNumofSplittable; sn++)
	{
		int buffId = sn;//pBuffIdVec_h[sn];
		if(testBestSplitPoint1[buffId].m_nFeatureId != -1 && testBestSplitPoint2[buffId].m_nFeatureId != -1)
		{
		if(testBestSplitPoint1[buffId].m_nFeatureId != testBestSplitPoint2[buffId].m_nFeatureId ||
		   abs(testBestSplitPoint1[buffId].m_fGain - testBestSplitPoint2[buffId].m_fGain) > deltaTest ||
		   abs(testBestSplitPoint1[buffId].m_fSplitValue - testBestSplitPoint2[buffId].m_fSplitValue) > deltaTest ||
		   abs(testpRChildStat[buffId].sum_gd - testpRChildStat2[buffId].sum_gd) > deltaTest ||
		   testpRChildStat[buffId].sum_hess != testpRChildStat2[buffId].sum_hess ||
		   abs(testpLChildStat[buffId].sum_gd - testpLChildStat2[buffId].sum_gd) > deltaTest ||
		   testpLChildStat[buffId].sum_hess != testpLChildStat2[buffId].sum_hess)
			cerr << "final result diff: " << testBestSplitPoint1[buffId].m_nFeatureId << " v.s. " << testBestSplitPoint2[buffId].m_nFeatureId
				 << "; " << testBestSplitPoint1[buffId].m_fGain << " v.s. " << testBestSplitPoint2[buffId].m_fGain
				 << "; " << testBestSplitPoint1[buffId].m_fSplitValue << " v.s. " << testBestSplitPoint2[buffId].m_fSplitValue
				 << "; r gd: " << testpRChildStat[buffId].sum_gd << " v.s. " << testpRChildStat2[buffId].sum_gd
				 << "; r hess: " << testpRChildStat[buffId].sum_hess << " v.s. " << testpRChildStat2[buffId].sum_hess
				 << "; l gd: " << testpLChildStat[buffId].sum_gd << " v.s. " << testpLChildStat2[buffId].sum_gd
				 << "; l hess: " << testpLChildStat[buffId].sum_hess << " v.s. " << testpLChildStat2[buffId].sum_hess
				 << endl;
		}


//		cout << "nid=" << pTestBuffIdVect[sn] << "; snid=" << sn << "; gain=" << testBestSplitPoint[pTestBuffIdVect[sn]].m_fGain << "; fid="
//			 << testBestSplitPoint[pTestBuffIdVect[sn]].m_nFeatureId << "; sv=" << testBestSplitPoint[pTestBuffIdVect[sn]].m_fSplitValue << endl;
	}
	delete []pBestGainEachNode_h;
	delete []testpRChildStat2;
	delete []testpLChildStat2;
	delete []testBestSplitPoint2;
	delete []testpRChildStat;
	delete []testpLChildStat;
	delete []testBestSplitPoint1;
	delete []testBestSplitPoint3;
	delete []testpRChildStat3;
	delete []testpLChildStat3;
#endif
	delete []pBuffIdVec_h;
	delete []pSNIdToBuffId_h;
}


