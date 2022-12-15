import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import PayloadConAndGen :: *;
import RespHandleSQ :: *;
import RetryHandleSQ :: *;
import ScanFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaResp :: *;
import Utils4Test :: *;
import Utils :: *;
import WorkCompGen :: *;

(* synthesize *)
module mkTestRespHandleNormalCase(Empty);
    let minDmaLength = 128;
    let maxDmaLength = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[1];
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        cntrl, pendingWorkReqPipeOut4PendingQ, pendingWorkReqBuf.fifoF
    );
    // Filter WR do not require WC
    let pendingWorkReqNeedWorkCompPipeOut <- mkPipeFilter(
        pendingWorkReqNeedWorkComp, existingPendingWorkReqPipeOutVec[2]
    );
    let pendingWorkReqPipeOut4Ref <- mkBufferN(4, pendingWorkReqNeedWorkCompPipeOut);
    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(4, simDmaReadSrv.dataStream);
    // Generate RDMA responses
    let rdmaRespAndHeaderPipeOut <- mkSimGenRdmaResp(
        cntrl, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeOut4RespGen
    );
    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaRespAndHeaderPipeOut.rdmaResp
    );
    // // Convert header DataStream to RdmaHeader
    // let rdmaHeaderPipeOut <- mkDataStream2Header(
    //     headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
    //     headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    // );
    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, pmtu
    );
    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl, pktMetaDataAndPayloadPipeOut.payload, simDmaWriteSrv.dmaWriteSrv
    );
    let retryHandler <- mkRetryHandleSQ(cntrl, pendingWorkReqBuf);
    // WorkCompGen
    let workCompGen <- mkWorkCompGen(
        cntrl,
        payloadConsumer.respPipeOut,
        pendingWorkReqBuf
    );

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl,
        pendingWorkReqBuf,
        pktMetaDataAndPayloadPipeOut.pktMetaData,
        payloadConsumer,
        retryHandler,
        workCompGen
    );

    rule compareWorkReqAndWorkComp;
        let pendingWR = pendingWorkReqPipeOut4Ref.first;
        pendingWorkReqPipeOut4Ref.deq;

        let workComp = workCompGen.workCompPipeOutSQ.first;
        workCompGen.workCompPipeOutSQ.deq;

        dynAssert(
            workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
            "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleSQ",
            $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
        );
    endrule

    rule comparePayloadDataStream;
        let payloadDataStream = simDmaWriteSrvDataStreamPipeOut.first;
        simDmaWriteSrvDataStreamPipeOut.deq;

        let refDataStream = simDmaReadSrvDataStreamPipeOut.first;
        simDmaReadSrvDataStreamPipeOut.deq;

        dynAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestRespHandleSQ",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule
