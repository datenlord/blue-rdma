import Connectable :: *;
import ClientServer :: *;
import GetPut :: *;
import FIFOF :: *;
import Clocks :: * ;
import Vector :: *;
import PAClib :: *;
import AlignedFIFOs :: * ;
import Probe::*;

import Axi4LiteTypes :: *;
import XilinxCmacController :: *;
import Ports :: *;
import EthernetTypes :: *;
import SemiFifo :: *;
import StreamHandler :: *;
import XilinxAxiStreamAsyncFifo :: *;
import UdpIpEthCmacRxTx :: *;
import UdpIpEthBypassCmacRxTx :: *;

import Settings :: *;
import RQ :: *;
import QPContext :: *;
import MetaData :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import RdmaUtils :: *;
import SendQ :: *;
import PayloadGen :: *;
import Headers :: *;

import ExtractAndPrependPipeOut :: *;

import MemRegionAndAddressTranslate :: *;
import PayloadCon :: *;
import XdmaWrapper :: *;

import UserLogicSettings :: *;
import UserLogicTypes :: *;
import Arbitration :: *;
import Ringbuf :: *;
import UserLogicUtils :: *;
import RegisterBlock :: *;
import CmdQueue :: *;
import WorkQueueRingbuf :: *;
import SoftReset :: *;

import PrimUtils :: *;

// import SimDma :: *;

typedef 4791 TEST_UDP_PORT;
typedef 32 CMAC_SYNC_BRAM_BUF_DEPTH;
typedef 4 CMAC_CDC_SYNC_STAGE;


interface BsvTop#(numeric type dataSz, numeric type userSz);
    interface XdmaChannel#(dataSz, userSz) xdmaChannel;
    interface RawAxi4LiteSlave#(CSR_ADDR_WIDTH, CSR_DATA_STRB_WIDTH) axilRegBlock;
    
    
    // Interface with CMAC IP
    (* prefix = "" *)
    interface XilinxCmacController cmacController;

    (* prefix = "", always_enabled *)
    method Bool csrSoftResetSignal;
endinterface


(* synthesize *)
module mkBsvTop(
    (* osc   = "cmac_rxtx_clk" *) Clock cmacRxTxClk,
    (* reset = "cmac_rx_resetn" *) Reset cmacRxReset,
    (* reset = "cmac_tx_resetn" *) Reset cmacTxReset,

    (* osc = "global_reset_100mhz_clk" *) Clock globalResetClk,
    (* reset = "global_reset_resetn" *) Reset globalResetReset,

    BsvTop#(USER_LOGIC_XDMA_KEEP_WIDTH, USER_LOGIC_XDMA_TUSER_WIDTH) ifc
);

    Clock dmacClock <- exposeCurrentClock;
    Reset dmacReset <- exposeCurrentReset;

    Clock udpClock <- exposeCurrentClock;
    Reset udpReset <- exposeCurrentReset;
    
    XdmaWrapper#(USER_LOGIC_XDMA_KEEP_WIDTH, USER_LOGIC_XDMA_TUSER_WIDTH) xdmaWrap <- mkXdmaWrapper;
    XdmaAxiLiteBridgeWrapper#(CsrAddr, CsrData) xdmaAxiLiteWrap <- mkXdmaAxiLiteBridgeWrapper(dmacClock, dmacReset);
    RdmaUserLogicWithoutXdmaAndCmacWrapper udpAndRdma <- mkRdmaUserLogicWithoutXdmaAndCmacWrapper(udpClock, udpReset, dmacClock, dmacReset);
    mkConnection(xdmaAxiLiteWrap.csrWriteClt, udpAndRdma.csrWriteSrv);
    mkConnection(xdmaAxiLiteWrap.csrReadClt, udpAndRdma.csrReadSrv);

`ifdef DO_BANDWIDTH_TEST
    let midLayer <- mkDmaReqMiddleLayerForBandwidthTest;
    mkConnection(midLayer.dmaReadSrv, udpAndRdma.dmaReadClt);
    mkConnection(midLayer.dmaWriteSrv, udpAndRdma.dmaWriteClt);
    mkConnection(xdmaWrap.dmaReadSrv, midLayer.dmaReadClt);
    mkConnection(xdmaWrap.dmaWriteSrv, midLayer.dmaWriteClt);
`else    
    mkConnection(xdmaWrap.dmaReadSrv, udpAndRdma.dmaReadClt);
    mkConnection(xdmaWrap.dmaWriteSrv, udpAndRdma.dmaWriteClt);
`endif


    Bool isCmacTxWaitRxAligned = True;
    Bool isEnableFlowControl = False;
    Bool isEnableRsFec = True;

    let axiStream512RxIn <- mkPutToFifoIn(udpAndRdma.axiStreamRxInUdp);

    let axiStream512SyncFifoForCMAC <- mkDuplexAxiStreamAsyncFifo(
        valueOf(CMAC_SYNC_BRAM_BUF_DEPTH),
        valueOf(CMAC_CDC_SYNC_STAGE),
        udpClock,
        udpReset,
        cmacRxTxClk,
        cmacRxReset,
        cmacTxReset,
        axiStream512RxIn,
        udpAndRdma.axiStreamTxOutUdp
    );


    FifoOut#(FlowControlReqVec) txFlowCtrlReqVec <- mkDummyFifoOut;
    FifoIn#(FlowControlReqVec) rxFlowCtrlReqVec <- mkDummyFifoIn;
    let xilinxCmacCtrl <- mkXilinxCmacController(
        isEnableRsFec,
        isEnableFlowControl,
        isCmacTxWaitRxAligned,
        axiStream512SyncFifoForCMAC.dstFifoOut,
        axiStream512SyncFifoForCMAC.dstFifoIn,
        txFlowCtrlReqVec,
        rxFlowCtrlReqVec,
        cmacRxReset,
        cmacTxReset,
        clocked_by cmacRxTxClk
    );

    let globalSoftReset <- mkGlobalSoftReset( globalResetClk,  globalResetReset);
    rule handleDoGlobalSoftReset;
        if (udpAndRdma.csrSoftResetSignal) begin
            globalSoftReset.doReset;
        end
    endrule

    interface xdmaChannel = xdmaWrap.xdmaChannel;
    interface axilRegBlock = xdmaAxiLiteWrap.cntrlAxil;
    interface cmacController = xilinxCmacCtrl;

    method csrSoftResetSignal = globalSoftReset.resetOut;
endmodule

interface UdpWrapper;
    interface UdpIpEthBypassRxTx netTxRxIfc;
endinterface

(* synthesize *)
module mkUdpWrapper(UdpWrapper);
    let udpCore <- mkGenericUdpIpEthBypassRxTx(`IS_SUPPORT_RDMA);
    interface netTxRxIfc = udpCore;
endmodule

interface RqWrapper;
    interface UserLogicDmaWriteClt dmaWriteClt;
    interface MrTableQueryClt mrTableQueryClt;
    interface PgtQueryClt pgtQueryClt;
    interface RqDataStreamWithExtraInfoPipeIn rdmaDataStreamInput;
    interface Server#(WriteReqCommonQPC, Bool) qpcWriteCommonSrv;
    interface PipeOut#(RingbufRawDescriptor) packetMetaDescPipeOutRQ;
    interface Put#(RawPacketReceiveMeta) rawPacketReceiveConfigIn;
    interface Put#(Tuple3#(IndexQP, PSN, RqPsnManagerPsnUpadteAction)) setRqExpectedPsnReqIn;
    interface PipeOut#(AutoAckGenMetaData)  autoAckMetaPipeOut;
endinterface


(* synthesize *)
module mkRqWrapper(RqWrapper);

    // TODO try remove this proxy.
    BluerdmaDmaProxyForRQ bluerdmaDmaProxyForRQ <- mkBluerdmaDmaProxyForRQ;

    RingbufStorage#(DATA, InputStreamFragBufferIdx) recvStreamFragStorage <- mkRingbufStorage("recvStreamFragStorage", True);
    RQ rqCore <- mkRQ;
    let inputRdmaPktBufAndHeaderValidation <- mkInputRdmaPktBufAndHeaderValidation;
    QPContext qpc <- mkQPContext;
    let payloadConsumer <- mkPayloadConsumer;
    RQReportEntryToRingbufDesc reportDescConvertor <- mkRQReportEntryToRingbufDesc;

    FIFOF#(RqDataStreamWithExtraInfo) inputDataStreamQ <- mkFIFOF;

    let rawPacketFakeHeaderInserterPipeout <- mkRawPacketFakeHeaderStreamInsert(toPipeOut(inputDataStreamQ));

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut;

    mkConnection(headerAndMetaDataAndPayloadPipeOut.rdmaPktPipeIn, toGet(rawPacketFakeHeaderInserterPipeout.streamPipeOut));

    mkConnection(toGet(headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData), inputRdmaPktBufAndHeaderValidation.headerMetaDataPipeIn);
    mkConnection(toGet(headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream), inputRdmaPktBufAndHeaderValidation.headerDataStreamPipeIn);
    mkConnection(toGet(headerAndMetaDataAndPayloadPipeOut.payloadStreamFragMetaPipeOut), inputRdmaPktBufAndHeaderValidation.payloadStreamFragMetaPipeIn);
    mkConnection(headerAndMetaDataAndPayloadPipeOut.payloadStreamFragStorageIdxIn, recvStreamFragStorage.allocSlotIdx);
    mkConnection(headerAndMetaDataAndPayloadPipeOut.payloadStreamFragStorageDataOut, recvStreamFragStorage.saveData);

    Reg#(Bit#(1)) queueFullDebugReg <- mkReg(-1);
    Probe#(Bit#(1)) queueFullDebugProbe1 <- mkProbe;
    rule debugFillQueueFullDebugReg;
        queueFullDebugReg <= queueFullDebugReg & {pack(inputDataStreamQ.notFull)};
        queueFullDebugProbe1 <= queueFullDebugReg;
    endrule

    // rule debugDropData;
    //     if (headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData.notEmpty) begin
    //         headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData.deq;
    //         $display("time=%0t", $time, "headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData.deq");
    //     end
    //     if (headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream.notEmpty) begin
    //         headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream.deq;
    //         $display("time=%0t", $time, "headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream.deq");
    //     end
    //     if (headerAndMetaDataAndPayloadPipeOut.payloadStreamFragMetaPipeOut.notEmpty) begin
    //         headerAndMetaDataAndPayloadPipeOut.payloadStreamFragMetaPipeOut.deq;
    //         $display("time=%0t", $time, "headerAndMetaDataAndPayloadPipeOut.payloadStreamFragMetaPipeOut.deq");
    //     end
    // endrule

    // rule debugDropFragStorageAndGenFakeResp;
    //     let _ <- headerAndMetaDataAndPayloadPipeOut.payloadStreamFragStorageInsertClt.request.get;
    //     headerAndMetaDataAndPayloadPipeOut.payloadStreamFragStorageInsertClt.response.put(unpack(0));
    //     $display("time=%0t", $time, "headerAndMetaDataAndPayloadPipeOut.payloadStreamFragStorageInsertClt.request.get");
    // endrule

    mkConnection(inputRdmaPktBufAndHeaderValidation.qpcReadCommonClt, qpc.readCommonSrv);
    mkConnection(toGet(inputRdmaPktBufAndHeaderValidation.reqPktPipeOut.pktMetaData), rqCore.pktMetaDataPipeIn);
    mkConnection(toGet(inputRdmaPktBufAndHeaderValidation.reqPktPipeOut.payloadStreamFragMetaPipeOut), payloadConsumer.payloadStreamFragMetaPipeIn);
    
    mkConnection(rqCore.payloadConsumerControlPortClt, payloadConsumer.controlPortSrv);
    mkConnection(payloadConsumer.readFragClt, recvStreamFragStorage.readFragSrv);
    
    mkConnection(toGet(rqCore.pktReportEntryPipeOut), reportDescConvertor.pktReportEntryPipeIn);

    mkConnection(payloadConsumer.dmaWriteClt, bluerdmaDmaProxyForRQ.blueSideWriteSrv);


    interface dmaWriteClt = bluerdmaDmaProxyForRQ.userlogicSideWriteClt;
    interface mrTableQueryClt = rqCore.mrTableQueryClt;
    interface pgtQueryClt = rqCore.pgtQueryClt;
    interface rdmaDataStreamInput = toPut(inputDataStreamQ);
    interface qpcWriteCommonSrv = qpc.writeCommonSrv;
    interface packetMetaDescPipeOutRQ = reportDescConvertor.ringbufDescPipeOut;
    interface rawPacketReceiveConfigIn = rawPacketFakeHeaderInserterPipeout.rawPacketReceiveConfigIn;
    interface setRqExpectedPsnReqIn = rqCore.setRqExpectedPsnReqIn;
    interface autoAckMetaPipeOut = rqCore.autoAckMetaPipeOut;
endmodule


interface QueuePair;
    interface RqWrapper rqIfc;
    interface SQ sqIfc;
endinterface

(* synthesize *)
module mkQueuePair(QueuePair);
    let rq <- mkRqWrapper;
    let sq <- mkSQ;
    interface rqIfc = rq;
    interface sqIfc = sq;
endmodule


interface RdmaUserLogicWithoutXdmaAndUdpCmacWrapper;
    // SQ
    interface PipeOut#(PktInfo4UDP) sqUdpInfoPipeOut;
    interface DataStreamPipeOut     sqRdmaDataStreamPipeOut;
    interface Put#(WorkQueueElem)   autoAckWqePipeIn;

    // RQ
    interface RqDataStreamWithExtraInfoPipeIn rqInputDataStream;
    interface PipeOut#(AutoAckGenMetaData) autoAckMetaPipeOut;
    
    // DMA Controller
    interface UserLogicDmaReadWideClt   dmaReadClt;
    interface UserLogicDmaWriteWideClt  dmaWriteClt;

    // CSR related
    interface Server#(CsrWriteRequest#(CsrAddr, CsrData), CsrWriteResponse)     csrWriteSrv;
    interface Server#(CsrReadRequest#(CsrAddr), CsrReadResponse#(CsrData))      csrReadSrv;
    method Bool csrSoftResetSignal;

    // UDP config related
    interface Get#(UdpConfig)    setNetworkParamReqOut;

endinterface


(* synthesize *)
module mkRdmaUserLogicWithoutXdmaAndUdpCmacWrapper(
    Clock dmacClock, 
    Reset dmacReset, 
    RdmaUserLogicWithoutXdmaAndUdpCmacWrapper ifc
);

    FIFOF#(WorkQueueElem)   autoAckWqePipeInQ <- mkFIFOF;

    RingbufPool#(RINGBUF_H2C_TOTAL_COUNT, RINGBUF_C2H_TOTAL_COUNT, RingbufRawDescriptor) ringbufPool <- mkRingbufPool;
    RegisterBlock#(CsrAddr, CsrData) csrBlock <- mkRegisterBlock(ringbufPool.h2cMetas, ringbufPool.c2hMetas);
    CommandQueueController cmdQController <- mkCommandQueueController;

    mkConnection(toGet(ringbufPool.h2cRings[0]), cmdQController.ringbufSrv.request);
    rule forwardCmdQResponseToRingbuf;
        let t <- cmdQController.ringbufSrv.response.get;
        ringbufPool.c2hRings[0].enq(t);
    endrule


    let qp <- mkQueuePair;
    mkConnection(cmdQController.setRawPacketReceiveMetaReqOut, qp.rqIfc.rawPacketReceiveConfigIn);
    mkConnection(cmdQController.setRqExpectedPsnReqOut, qp.rqIfc.setRqExpectedPsnReqIn);

    DmaReqAddrTranslator addrTranslatorForSQ <- mkDmaReadReqAddrTranslator;
    function Bool alwaysTrue(anytype t) = True;

    MemRegionTable mrTable <- mkMemRegionTable;

    Vector#(2, MrTableQueryClt)  mrTableQueryCltVec = newVector;
    mrTableQueryCltVec[0] = qp.rqIfc.mrTableQueryClt;
    mrTableQueryCltVec[1] = addrTranslatorForSQ.mrTableClt;
    let mrTableQueryArbitClt <- mkClientArbiter("mrTableQueryArbitClt", False, 10, mrTableQueryCltVec, alwaysTrue, alwaysTrue);
    mkConnection(mrTable.querySrv, mrTableQueryArbitClt);

    TLB tlb <- mkTLB;
    Vector#(2, PgtQueryClt)  tlbQueryCltVec = newVector;
    tlbQueryCltVec[0] = qp.rqIfc.pgtQueryClt;
    tlbQueryCltVec[1] = addrTranslatorForSQ.addrTransClt;
    let tlbQueryArbitClt <- mkClientArbiter("tlbQueryArbitClt", False, 10, tlbQueryCltVec, alwaysTrue, alwaysTrue);
    mkConnection(tlb.translateSrv, tlbQueryArbitClt);

    MrAndPgtManager mrAndPgtManager <- mkMrAndPgtManager;
    mkConnection(mrAndPgtManager.mrModifyClt, mrTable.modifySrv);
    mkConnection(mrAndPgtManager.pgtModifyClt, tlb.modifySrv);
    mkConnection(cmdQController.mrAndPgtManagerClt, mrAndPgtManager.mrAndPgtModifyDescSrv);
    mkConnection(cmdQController.qpcModifyClt, qp.rqIfc.qpcWriteCommonSrv);


    WorkQueueRingbufController workQueueRingbufController <- mkWorkQueueRingbufController;
    mkConnection(workQueueRingbufController.sqRingBuf, toGet(ringbufPool.h2cRings[1]));


    function Bool isH2cDmaReqFinished(UserLogicDmaH2cReq req) = True;
    function Bool isH2cDmaRespFinished(UserLogicDmaH2cResp resp) = resp.dataStream.isLast;
    function Bool isC2hDmaReqFinished(UserLogicDmaC2hReq req) = req.dataStream.isLast;
    function Bool isC2hDmaRespFinished(UserLogicDmaC2hResp resp) = True;
    
    Vector#(4, UserLogicDmaReadClt)  dmaAccessH2cCltVec = newVector;
    Vector#(2, UserLogicDmaWriteClt) dmaAccessC2hCltVec = newVector;


    // dmaAccessH2cCltVec[0] <- mkFakeClient;
    dmaAccessH2cCltVec[0] = addrTranslatorForSQ.sqReqOutputClt;
    dmaAccessH2cCltVec[1] = ringbufPool.dmaAccessH2cClt;
    dmaAccessH2cCltVec[2] = mrAndPgtManager.pgtDmaReadClt;
    dmaAccessH2cCltVec[3] <- mkFakeClient;

    dmaAccessC2hCltVec[0] = qp.rqIfc.dmaWriteClt;
    dmaAccessC2hCltVec[1] = ringbufPool.dmaAccessC2hClt;

    UserLogicDmaReadClt xdmaReadClt <- mkClientArbiter("xdmaReadClt", False, 10, dmaAccessH2cCltVec, isH2cDmaReqFinished, isH2cDmaRespFinished);
    UserLogicDmaWriteClt xdmaWriteClt <- mkClientArbiter("xdmaWriteClt", False, 10, dmaAccessC2hCltVec, isC2hDmaReqFinished, isC2hDmaRespFinished);
`ifdef IS_250MHZ_512BITS
    XdmaGearbox xdmaGearbox <- mkXdmaBypassGearbox;
`else
    XdmaGearbox xdmaGearbox <- mkXdmaGearbox(dmacClock, dmacReset);
`endif
    mkConnection(xdmaReadClt, xdmaGearbox.h2cStreamSrv);
    mkConnection(xdmaWriteClt, xdmaGearbox.c2hStreamSrv);
    
    mkConnection(qp.sqIfc.dmaReadClt, addrTranslatorForSQ.sqReqInputSrv);

    // rule debug;
    //     if (!qp.sqIfc.sendQ.dataStreamPipeOutSQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: qp.sqIfc.sendQ.dataStreamPipeOutSQ");
    //     end
    //     if (!qp.sqIfc.sendQ.udpInfoPipeOutSQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: qp.sqIfc.sendQ.udpInfoPipeOutSQ");
    //     end 
    // endrule



    rule arbitUserWqeAndAutoAckWqe;
        if (autoAckWqePipeInQ.notEmpty) begin
            autoAckWqePipeInQ.deq;
            qp.sqIfc.sendQ.wqeSrv.request.put(autoAckWqePipeInQ.first);
            $display("time=%0t: ", $time, "arbiter enqueue WQE to SQ, ACK WQE=", fshow(autoAckWqePipeInQ.first));
        end
        else if (workQueueRingbufController.workReq.notEmpty) begin
            workQueueRingbufController.workReq.deq;
            qp.sqIfc.sendQ.wqeSrv.request.put(workQueueRingbufController.workReq.first);
            $display("time=%0t: ", $time, "arbiter enqueue WQE to SQ, User WQE=", fshow(workQueueRingbufController.workReq.first));
        end
    endrule

    rule forwardRecvQueuePktReportDescToRingbuf;
        let t = qp.rqIfc.packetMetaDescPipeOutRQ.first;
        qp.rqIfc.packetMetaDescPipeOutRQ.deq;
        ringbufPool.c2hRings[1].enq(t);
    endrule

    rule forwardSendQueueReportDescToRingbuf;
        let _ <- qp.sqIfc.sendQ.wqeSrv.response.get;
    endrule


    // SQ
    interface sqUdpInfoPipeOut = qp.sqIfc.sendQ.udpInfoPipeOutSQ;
    interface sqRdmaDataStreamPipeOut = qp.sqIfc.sendQ.dataStreamPipeOutSQ;
    interface autoAckWqePipeIn = toPut(autoAckWqePipeInQ);

    // RQ
    interface rqInputDataStream = qp.rqIfc.rdmaDataStreamInput;
    interface autoAckMetaPipeOut = qp.rqIfc.autoAckMetaPipeOut;

    interface dmaReadClt = xdmaGearbox.h2cStreamClt;
    interface dmaWriteClt = xdmaGearbox.c2hStreamClt;
    interface csrWriteSrv = csrBlock.csrWriteSrv;
    interface csrReadSrv = csrBlock.csrReadSrv;

    interface setNetworkParamReqOut = cmdQController.setNetworkParamReqOut;

    method csrSoftResetSignal = csrBlock.csrSoftResetSignal;
endmodule

typedef enum {
    UdpReceivingChannelSelectStateNotInit       = 0,
    UdpReceivingChannelSelectStateIdle          = 1,
    UdpReceivingChannelSelectStateRecvRdmaData  = 2,
    UdpReceivingChannelSelectStateRecvRawData   = 3
} UdpReceivingChannelSelectState deriving(Bits, Eq);




interface RdmaUserLogicWithoutXdmaAndCmacWrapper;
    interface AxiStream512FifoOut axiStreamTxOutUdp;
    interface Put#(AxiStream512)   axiStreamRxInUdp;
    
    interface UserLogicDmaReadWideClt dmaReadClt;
    interface UserLogicDmaWriteWideClt dmaWriteClt;

    interface Server#(CsrWriteRequest#(CsrAddr, CsrData), CsrWriteResponse) csrWriteSrv;
    interface Server#(CsrReadRequest#(CsrAddr), CsrReadResponse#(CsrData)) csrReadSrv;
    
    method Bool csrSoftResetSignal;
endinterface


(* synthesize *)
module mkRdmaUserLogicWithoutXdmaAndCmacWrapper(
    Clock udpClock, 
    Reset udpReset, 
    Clock dmacClock, 
    Reset dmacReset, 
    RdmaUserLogicWithoutXdmaAndCmacWrapper ifc
);

    let rdmaClock <- exposeCurrentClock;
    let rdmaReset <- exposeCurrentReset;

    let rdma <- mkRdmaUserLogicWithoutXdmaAndUdpCmacWrapper(dmacClock, dmacReset);
    let udp <- mkUdpWrapper;

    // let udpGearbox <- mkUdpGearbox(rdmaClock, rdmaReset, udpClock, udpReset);

    Reg#(UdpReceivingChannelSelectState)  isReceivingRawPacketReg <- mkReg(UdpReceivingChannelSelectStateNotInit);

    RingbufStorage#(RecvPacketSrcMacIpBufferEntry, RecvPacketSrcMacIpBufferIdx) recvMacIpStorage <- mkRingbufStorage("recvMacIpStorage", False);

    FIFOF#(Ports::DataStream) udpTxStreamBufQ <- mkFIFOF;
    FIFOF#(UdpIpMetaData) udpTxIpMetaBufQ <- mkFIFOF;
    FIFOF#(MacMetaDataWithBypassTag) udpTxMacMetaBufQ <- mkFIFOF;
    FIFOF#(RqDataStreamWithExtraInfo) udpRxStreamBufQ <- mkSizedFIFOF(1024);

    FIFOF#(AutoAckGenMetaData) sendAutoAckMacIpStorageReadPipeQ <- mkFIFOF;

    FIFOF#(DataStream) rdmaPacketDataStreamRelyQ <- mkFIFOF;
    FIFOF#(DataStream) rawPacketDataStreamRelyQ <- mkFIFOF;


    mkConnection(toGet(udpTxStreamBufQ), udp.netTxRxIfc.dataStreamTxIn);
    mkConnection(toGet(udpTxIpMetaBufQ), udp.netTxRxIfc.udpIpMetaDataTxIn);
    mkConnection(toGet(udpTxMacMetaBufQ), udp.netTxRxIfc.macMetaDataTxIn);
    mkConnection(toGet(udpRxStreamBufQ), rdma.rqInputDataStream);

    Reg#(Bit#(1)) queueFullDebugReg <- mkReg(-1);
    Probe#(Bit#(1)) queueFullDebugProbe <- mkProbe;
    rule debugFillQueueFullDebugReg;
        queueFullDebugReg <= queueFullDebugReg & {pack(udpRxStreamBufQ.notFull)};
        queueFullDebugProbe <= queueFullDebugReg;
    endrule

    // mkConnection(toGet(rdma.setNetworkParamReqOut), toPut(udp.netTxRxIfc.udpConfig));


    // rule debug;
    //     // if (!udpTxStreamBufQ.notFull) begin
    //     //     $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: udpTxStreamBufQ");
    //     // end

    //     if (!udp.netTxRxIfc.dataStreamRxOut.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: udp.netTxRxIfc.dataStreamRxOut");
    //     end
    //     if (!udp.netTxRxIfc.udpIpMetaDataRxOut.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: udp.netTxRxIfc.udpIpMetaDataRxOut");
    //     end
    //     if (!udp.netTxRxIfc.macMetaDataRxOut.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: udp.netTxRxIfc.macMetaDataRxOut");
    //     end

    //     if (!udpRxStreamBufQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: udpRxStreamBufQ");
    //     end
    // endrule

    Reg#(Bool) udpConfigInitedReg <- mkReg(False);
    rule initAndForwardUdpConfig;
        let cfg <- rdma.setNetworkParamReqOut.get;
        udp.netTxRxIfc.udpConfig.put(cfg);
        // udp.netTxRxIfc.udpConfig.put(UdpConfig{
        //     macAddr: 'hAABBCCDDEEFF,
        //     ipAddr:     'h7F000003,
        //     netMask:  'h0,
        //     gateWay:  'h0
        // } );
        udpConfigInitedReg <= True;
    endrule

    rule changeRxChannelStateToInit if (isReceivingRawPacketReg == UdpReceivingChannelSelectStateNotInit);

        Maybe#(Bool) isLast = tagged Invalid;

        if (udp.netTxRxIfc.dataStreamRxOut.notEmpty) begin
            let data = udp.netTxRxIfc.dataStreamRxOut.first;
            udp.netTxRxIfc.dataStreamRxOut.deq;
            if (data.isFirst) begin
                udp.netTxRxIfc.macMetaDataRxOut.deq;
                udp.netTxRxIfc.udpIpMetaDataRxOut.deq;
            end
            isLast = tagged Valid data.isLast;
        end
        else if (udp.netTxRxIfc.rawPktStreamRxOut.notEmpty) begin
            let data = udp.netTxRxIfc.rawPktStreamRxOut.first;
            udp.netTxRxIfc.rawPktStreamRxOut.deq;
            isLast = tagged Valid data.isLast;
        end

        if (udpConfigInitedReg) begin
            if (!isValid(isLast)) begin
                isReceivingRawPacketReg <= UdpReceivingChannelSelectStateIdle;
            end
            else if (isLast matches tagged Valid .value) begin
                if (value == True) begin
                    isReceivingRawPacketReg <= UdpReceivingChannelSelectStateIdle;
                end
            end
        end
    endrule

    Reg#(Bit#(14)) forwardTxStreamCntReg <- mkReg(0);

    rule forwardTxStream;
        rdma.sqRdmaDataStreamPipeOut.deq;
        let data = dataStream2DataStreamEnLeftAlign(rdma.sqRdmaDataStreamPipeOut.first);
        $display("time=%0t: ", $time,"rdma put data to udp = ", fshow(data));
        udpTxStreamBufQ.enq(Ports::DataStream{
            data: swapEndian(data.data),
            byteEn: swapEndianBit(data.byteEn),
            isFirst:    data.isFirst,
            isLast:     data.isLast
        });
        if (data.isFirst) begin
            forwardTxStreamCntReg <= forwardTxStreamCntReg + 1;
        end
    endrule

    rule forwardTxMeta;
        rdma.sqUdpInfoPipeOut.deq;
        let meta = rdma.sqUdpInfoPipeOut.first;
        $display("time=%0t: ", $time,"rdma_out_meta = ", fshow(meta));

        IpAddr dstIP = unpack(0);

        if (meta.ipAddr matches tagged IPv4 .ipv4) begin
            dstIP = unpack(pack(ipv4));
        end 
        else begin
            $display("Error: Dest IP addr is not IPv4");
            $finish;
        end

        if (!meta.isRawPkt) begin
            udpTxIpMetaBufQ.enq(UdpIpMetaData{
                dataLen: zeroExtend(meta.pktLen),
                ipAddr:  dstIP,
                ipDscp:  0,
                ipEcn:   0,
                dstPort: fromInteger(valueOf(TEST_UDP_PORT)),
                srcPort: fromInteger(valueOf(TEST_UDP_PORT))
            });
        end

        udpTxMacMetaBufQ.enq(MacMetaDataWithBypassTag{
            macMetaData: MacMetaData{
                macAddr: unpack(pack(meta.macAddr)),
                ethType: fromInteger(valueOf(ETH_TYPE_IP))
            },
            isBypass: meta.isRawPkt
        });

    endrule

    rule forwardRdmaRxStreamIdle if (isReceivingRawPacketReg == UdpReceivingChannelSelectStateIdle);
        
        if (udp.netTxRxIfc.dataStreamRxOut.notEmpty) begin
            let srcMacIpIdx <- recvMacIpStorage.allocSlotIdx.get;
            udp.netTxRxIfc.udpIpMetaDataRxOut.deq;
            udp.netTxRxIfc.macMetaDataRxOut.deq;

            recvMacIpStorage.saveData.put(tuple2(srcMacIpIdx, RecvPacketSrcMacIpBufferEntry{
                ip     : tagged IPv4 unpack(pack(udp.netTxRxIfc.udpIpMetaDataRxOut.first.ipAddr)),
                macAddr: unpack(pack(udp.netTxRxIfc.macMetaDataRxOut.first.macAddr))
            }));

            let data = udp.netTxRxIfc.dataStreamRxOut.first;
            udp.netTxRxIfc.dataStreamRxOut.deq;
            let outData = dataStreamEnLeftAlign2DataStream(DataTypes::DataStreamEn {
                data: swapEndian(data.data),
                byteEn: swapEndianBit(data.byteEn),
                isLast: data.isLast,
                isFirst: data.isFirst
            });
            udpRxStreamBufQ.enq(tuple3(outData, False, srcMacIpIdx));
            $display("time=%0t: ", $time,"udp put to rqWrapper rdmaData = ", fshow(outData), ", origin data = ", fshow(data));

            if (!data.isLast) begin
                isReceivingRawPacketReg <= UdpReceivingChannelSelectStateRecvRdmaData;
            end
        end
        else if (udp.netTxRxIfc.rawPktStreamRxOut.notEmpty) begin
            let srcMacIpIdx <- recvMacIpStorage.allocSlotIdx.get;
            recvMacIpStorage.saveData.put(tuple2(srcMacIpIdx, RecvPacketSrcMacIpBufferEntry{
                ip     : tagged IPv4 unpack(0),
                macAddr: unpack(0)
            }));

            let data = udp.netTxRxIfc.rawPktStreamRxOut.first;
            udp.netTxRxIfc.rawPktStreamRxOut.deq;
            let outData = dataStreamEnLeftAlign2DataStream(DataTypes::DataStreamEn {
                data: swapEndian(data.data),
                byteEn: swapEndianBit(data.byteEn),
                isLast: data.isLast,
                isFirst: data.isFirst
            });
            udpRxStreamBufQ.enq(tuple3(outData, True, srcMacIpIdx));
            $display("time=%0t: ", $time,"udp put to rqWrapper rawData = ", fshow(outData), ", origin data = ", fshow(data));

            if (!data.isLast) begin
                isReceivingRawPacketReg <= UdpReceivingChannelSelectStateRecvRawData;
            end
        end
    endrule

    rule forwardRdmaRxStreamRdmaData if (isReceivingRawPacketReg == UdpReceivingChannelSelectStateRecvRdmaData);
       
        let data = udp.netTxRxIfc.dataStreamRxOut.first;
        udp.netTxRxIfc.dataStreamRxOut.deq;
        let outData = dataStreamEnLeftAlign2DataStream(DataTypes::DataStreamEn {
            data: swapEndian(data.data),
            byteEn: swapEndianBit(data.byteEn),
            isLast: data.isLast,
            isFirst: data.isFirst
        });
        udpRxStreamBufQ.enq(tuple3(outData, False, ?));
        $display("time=%0t: ", $time,"udp put to rqWrapper rdmaData = ", fshow(outData), ", origin data = ", fshow(data));
        if (data.isLast) begin
            isReceivingRawPacketReg <= UdpReceivingChannelSelectStateIdle;
        end
    endrule

    rule forwardRdmaRxStreamRawData if (isReceivingRawPacketReg == UdpReceivingChannelSelectStateRecvRawData);

        let data = udp.netTxRxIfc.rawPktStreamRxOut.first;
        udp.netTxRxIfc.rawPktStreamRxOut.deq;
        let outData = dataStreamEnLeftAlign2DataStream(DataTypes::DataStreamEn {
            data: swapEndian(data.data),
            byteEn: swapEndianBit(data.byteEn),
            isLast: data.isLast,
            isFirst: data.isFirst
        });
        udpRxStreamBufQ.enq(tuple3(outData, True, ?));
        $display("time=%0t: ", $time,"udp put to rqWrapper rawData = ", fshow(outData), ", origin data = ", fshow(data));
        if (data.isLast) begin
            isReceivingRawPacketReg <= UdpReceivingChannelSelectStateIdle;
        end
    endrule

    rule sendAutoAckMacIpStorageReadReq;
        let autoAckMeta = rdma.autoAckMetaPipeOut.first;
        rdma.autoAckMetaPipeOut.deq;
        recvMacIpStorage.readFragSrv.request.put(tuple2(autoAckMeta.srcMacIpIdx, False));
        sendAutoAckMacIpStorageReadPipeQ.enq(autoAckMeta);
    endrule

    rule generateAutoAckWqe;
        let macIp <- recvMacIpStorage.readFragSrv.response.get;

        let autoAckMeta = sendAutoAckMacIpStorageReadPipeQ.first;
        sendAutoAckMacIpStorageReadPipeQ.deq;

        ScatterGatherList sgl = unpack(0);
        sgl[0].isFirst = True;
        sgl[0].isLast = True;

        let autoGeneratedWQE = WorkQueueElem {
            pkey: autoAckMeta.pkey,
            opcode: IBV_WR_RDMA_ACK,
            flags: enum2Flag(IBV_SEND_NO_FLAGS),
            qpType: IBV_QPT_RC,
            psn: autoAckMeta.expectedPsn,
            pmtu: IBV_MTU_256,
            dqpIP: macIp.ip,
            macAddr: macIp.macAddr,
            sgl: sgl,
            totalLen: 0,
            raddr: 0,
            rkey: 0,
            sqpn: 0, // TODO: remove it
            dqpn: autoAckMeta.qpn,
            comp: tagged Invalid,
            swap: tagged Invalid,
            immDtOrInvRKey: tagged Invalid,
            srqn: tagged Invalid, // for XRC
            qkey: tagged Invalid, // for UD
            isFirst: True,
            isLast: True
        };
        rdma.autoAckWqePipeIn.put(autoGeneratedWQE);
    endrule
    
   

    interface axiStreamTxOutUdp = udp.netTxRxIfc.axiStreamTxOut;
    interface axiStreamRxInUdp = udp.netTxRxIfc.axiStreamRxIn;


    interface dmaReadClt = rdma.dmaReadClt;
    interface dmaWriteClt = rdma.dmaWriteClt;
    interface csrWriteSrv = rdma.csrWriteSrv;
    interface csrReadSrv = rdma.csrReadSrv;

    method csrSoftResetSignal = rdma.csrSoftResetSignal;
endmodule
