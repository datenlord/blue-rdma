import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import Settings :: *;
import SimDma :: *;
import TransportLayer :: *;
import Utils :: *;
import Utils4Test :: *;

(* synthesize *)
module mkTestTransportLayerNormalCase(Empty);
    let normalOrErrCase = True;
    let result <- mkTestTransportLayerNormalOrErrCase(normalOrErrCase);
endmodule

module mkTestTransportLayerErrorCase(Empty);
    let normalOrErrCase = False;
    let result <- mkTestTransportLayerNormalOrErrCase(normalOrErrCase);
endmodule

module mkTestTransportLayerNormalOrErrCase#(Bool normalOrErrCase)(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND; // IBV_QPT_RC; //
    let pmtu = IBV_MTU_512;
    let isSendSideQ = True;

    FIFOF#(QPN) dqpnQ4RecvSide <- mkFIFOF;
    // FIFOF#(QPN) dqpnQ4SendSide <- mkFIFOF;

    FIFOF#(RKEY) recvSideRKeyQ4Write  <- mkFIFOF;
    FIFOF#(RKEY) recvSideRKeyQ4Read   <- mkFIFOF;
    FIFOF#(RKEY) recvSideRKeyQ4Atomic <- mkFIFOF;
    // FIFOF#(RKEY) sendSideRKeyQ4Write  <- mkFIFOF;
    // FIFOF#(RKEY) sendSideRKeyQ4Read   <- mkFIFOF;
    // FIFOF#(RKEY) sendSideRKeyQ4Atomic <- mkFIFOF;

    let recvSideTransportLayer <- mkTransportLayer;
    let initRecvSide <- mkInitMetaDataAndConnectQP(
        recvSideTransportLayer,
        toPipeOut(dqpnQ4RecvSide),
        toPipeOut(recvSideRKeyQ4Write),
        toPipeOut(recvSideRKeyQ4Read),
        toPipeOut(recvSideRKeyQ4Atomic),
        minDmaLength,
        maxDmaLength,
        qpType,
        pmtu,
        !isSendSideQ,
        normalOrErrCase
    );
    let noWorkCompOutRule4RecvSideSendQ <- addRules(genEmptyPipeOutRule(
        recvSideTransportLayer.workCompPipeOutSQ,
        "recvSideTransportLayer.workCompPipeOutSQ empty assertion @ mkTestTransportLayerNormalCase"
    ));

    let simDmaReadSrv4RecvSide  <- mkSimDmaReadSrv;
    let simDmaWriteSrv4RecvSide <- mkSimDmaWriteSrv;
    let recvSideDmaRead <- mkConnection(
        recvSideTransportLayer.dmaReadClt, simDmaReadSrv4RecvSide
    );
    let recvSideDmaWrite <- mkConnection(
        recvSideTransportLayer.dmaWriteClt, simDmaWriteSrv4RecvSide
    );

    let sendSideTransportLayer <- mkTransportLayer;
    let initSendSide <- mkInitMetaDataAndConnectQP(
        sendSideTransportLayer,
        initRecvSide.qpnPipeOut,
        initRecvSide.rkeyPipeOut4Write,
        initRecvSide.rkeyPipeOut4Read,
        initRecvSide.rkeyPipeOut4Atomic,
        // toPipeOut(dqpnQ4SendSide),
        // toPipeOut(sendSideRKeyQ4Write),
        // toPipeOut(sendSideRKeyQ4Read),
        // toPipeOut(sendSideRKeyQ4Atomic),
        minDmaLength,
        maxDmaLength,
        qpType,
        pmtu,
        isSendSideQ,
        normalOrErrCase
    );
    let noWorkCompOutRule4SendSideRecvQ <- addRules(genEmptyPipeOutRule(
        sendSideTransportLayer.workCompPipeOutRQ,
        "sendSideTransportLayer.workCompPipeOutRQ empty assertion @ mkTestTransportLayerNormalCase"
    ));

    let simDmaReadSrv4SendSide  <- mkSimDmaReadSrv;
    let simDmaWriteSrv4SendSide <- mkSimDmaWriteSrv;
    let sendSideDmaRead <- mkConnection(
        sendSideTransportLayer.dmaReadClt, simDmaReadSrv4SendSide
    );
    let sendSideDmaWrite <- mkConnection(
        sendSideTransportLayer.dmaWriteClt, simDmaWriteSrv4SendSide
    );

    // mkSink(sendSideTransportLayer.rdmaDataStreamPipeOut);
    let req2RecvSide <- mkConnection(
        toGet(sendSideTransportLayer.rdmaDataStreamPipeOut),
        recvSideTransportLayer.rdmaDataStreamInput
    );
    let resp2SendSide <- mkConnection(
        toGet(recvSideTransportLayer.rdmaDataStreamPipeOut),
        sendSideTransportLayer.rdmaDataStreamInput
    );

    let qpnSendSide2RecvSide <- mkConnection(
        toGet(initSendSide.qpnPipeOut), toPut(dqpnQ4RecvSide)
    );
    // rule popSendSideQPN;
    //     let qpnSendSide = initSendSide.qpnPipeOut.first;
    //     initSendSide.qpnPipeOut.deq;
    //     dqpnQ4RecvSide.enq(qpnSendSide);
    // endrule
/*
    let qpnRecvSide2SendSide <- mkConnection(
        toGet(initRecvSide.qpnPipeOut), toPut(dqpnQ4SendSide)
    );
    // rule popRecvSideQPN;
    //     let qpnRecvSide = initRecvSide.qpnPipeOut.first;
    //     initRecvSide.qpnPipeOut.deq;
    //     dqpnQ4SendSide.enq(qpnRecvSide);
    // endrule

    let rkeyWrite2SendSide <- mkConnection(
        toGet(initRecvSide.rkeyPipeOut4Write), toPut(sendSideRKeyQ4Write)
    );
    // rule popRecvSideWriteRKey;
    //     let rkey4Write = initRecvSide.rkeyPipeOut4Write.first;
    //     initRecvSide.rkeyPipeOut4Write.deq;
    //     sendSideRKeyQ4Write.enq(rkey4Write);
    // endrule

    let rkeyRead2SendSide <- mkConnection(
        toGet(initRecvSide.rkeyPipeOut4Read), toPut(sendSideRKeyQ4Read)
    );
    // rule popRecvSideReadRKey;
    //     let rkey4Read = initRecvSide.rkeyPipeOut4Read.first;
    //     initRecvSide.rkeyPipeOut4Read.deq;
    //     sendSideRKeyQ4Read.enq(rkey4Read);
    // endrule

    let rkeyAtomic2SendSide <- mkConnection(
        toGet(initRecvSide.rkeyPipeOut4Atomic), toPut(sendSideRKeyQ4Atomic)
    );
    // rule popRecvSideAtomicRKey;
    //     let rkey4Atomic = initRecvSide.rkeyPipeOut4Atomic.first;
    //     initRecvSide.rkeyPipeOut4Atomic.deq;
    //     sendSideRKeyQ4Atomic.enq(rkey4Atomic);
    // endrule
*/
endmodule

typedef enum {
    META_DATA_ALLOC_PD,
    META_DATA_ALLOC_MR,
    META_DATA_CREATE_QP,
    META_DATA_INIT_QP,
    META_DATA_SET_QP_RTR,
    META_DATA_SET_QP_RTS,
    META_DATA_SEND_RR,
    META_DATA_SEND_WR,
    META_DATA_WRITE_WR,
    META_DATA_READ_WR,
    META_DATA_ATOMIC_WR,
    META_DATA_CHECK_RR,
    META_DATA_CHECK_SEND_WC,
    META_DATA_CHECK_WRITE_WC,
    META_DATA_CHECK_READ_WC,
    META_DATA_CHECK_ATOMIC_WC,
    META_DATA_SET_QP_ERR,
    META_DATA_DESTROY_QP,
    META_DATA_NO_OP
} InitMetaDataState deriving(Bits, Eq, FShow);

interface InitMetaDataAndConnectQP;
    interface PipeOut#(QPN) qpnPipeOut;
    // interface PipeOut#(RKEY) rkeyPipeOut4Send;
    interface PipeOut#(RKEY) rkeyPipeOut4Write;
    interface PipeOut#(RKEY) rkeyPipeOut4Read;
    interface PipeOut#(RKEY) rkeyPipeOut4Atomic;
endinterface

typedef 4 RDMA_REQ_TYPE_NUM;

module mkInitMetaDataAndConnectQP#(
    TransportLayer transportLayer,
    PipeOut#(QPN) dqpnPipeIn,
    PipeOut#(RKEY) rkeyPipeIn4Write,
    PipeOut#(RKEY) rkeyPipeIn4Read,
    PipeOut#(RKEY) rkeyPipeIn4Atomic,
    Length minDmaLength,
    Length maxDmaLength,
    TypeQP qpType,
    PMTU pmtu,
    Bool isSendSideQ,
    Bool normalOrErrCase
)(InitMetaDataAndConnectQP) provisos(
    NumAlias#(TDiv#(MAX_QP, MAX_PD), avgQpPerPD),
    NumAlias#(TDiv#(MAX_MR, MAX_QP), avgMrPerQP),
    NumAlias#(TDiv#(MAX_MR, RDMA_REQ_TYPE_NUM), avgMrPerReqType),
    NumAlias#(TDiv#(MAX_MR, TMul#(MAX_QP, RDMA_REQ_TYPE_NUM)), avgMrPerReqTypeQP),
    Add#(TMul#(MAX_PD, avgQpPerPD), 0, MAX_QP), // MAX_QP can be divided by MAX_PD
    Add#(TMul#(MAX_QP, avgMrPerQP), 0, MAX_MR), // MAX_MR can be divided by MAX_QP
    Add#(TMul#(RDMA_REQ_TYPE_NUM, avgMrPerReqType), 0, MAX_MR), // MAX_MR can be divied by RDMA_REQ_TYPE_NUM
    Add#(TMul#(TMul#(MAX_QP, RDMA_REQ_TYPE_NUM), avgMrPerReqTypeQP), 0, MAX_MR), // MAX_MR can be divied by RDMA_REQ_TYPE_NUM * MAX_QP
    Add#(RDMA_REQ_TYPE_NUM, anysize, avgMrPerQP) // avgMrPerQP should >= RDMA_REQ_TYPE_NUM
);
    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let qpAttrPipeOut <- mkSimQpAttrPipeOut(
        pmtu, setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );

    let pdNum = valueOf(MAX_PD);
    let qpNum = valueOf(MAX_QP);
    let mrNum = valueOf(MAX_MR);
    let mrPerPD = valueOf(MAX_MR_PER_PD);
    let qpPerPD = valueOf(avgQpPerPD);
    let mrPerQP = valueOf(avgMrPerQP);

    let metaDataSrv = transportLayer.srvPortMetaData;

    Reg#(Bool) pdHandlerVecValidReg <- mkReg(False);
    Reg#(Bool)      lkeyVecValidReg <- mkReg(False);
    Reg#(Bool)      rkeyVecValidReg <- mkReg(False);

    Vector#(MAX_PD, Reg#(HandlerPD))  pdHandlerVec4ReqMR <- replicateM(mkRegU);
    Vector#(MAX_PD, Reg#(HandlerPD))  pdHandlerVec4ReqQP <- replicateM(mkRegU);

    let pdHandlerPipeOut4ReqMR <- mkVector2PipeOut(
        readVReg(pdHandlerVec4ReqMR), pdHandlerVecValidReg
    );
    let pdHandlerPipeOut4ReqQP <- mkVector2PipeOut(
        readVReg(pdHandlerVec4ReqQP), pdHandlerVecValidReg
    );

    FIFOF#(HandlerPD) pdHandlerQ4RespMR <- mkSizedFIFOF(mrNum);
    FIFOF#(HandlerPD) pdHandlerQ4RespQP <- mkSizedFIFOF(qpNum);

    Vector#(avgMrPerReqType, Reg#(LKEY)) lkeyVec4Recv   <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(LKEY)) lkeyVec4Send   <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(LKEY)) lkeyVec4Write  <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(LKEY)) lkeyVec4Read   <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(LKEY)) lkeyVec4Atomic <- replicateM(mkRegU);
    // Vector#(avgMrPerReqType, Reg#(RKEY)) rkeyVec4Send   <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(RKEY)) rkeyVec4Write  <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(RKEY)) rkeyVec4Read   <- replicateM(mkRegU);
    Vector#(avgMrPerReqType, Reg#(RKEY)) rkeyVec4Atomic <- replicateM(mkRegU);

    // FIFOF#(LKEY) lkeyQ4Recv   <- mkSizedFIFOF(qpNum);
    // FIFOF#(LKEY) lkeyQ4Send   <- mkSizedFIFOF(qpNum);
    // FIFOF#(LKEY) lkeyQ4Write  <- mkSizedFIFOF(qpNum);
    // FIFOF#(LKEY) lkeyQ4Read   <- mkSizedFIFOF(qpNum);
    // FIFOF#(LKEY) lkeyQ4Atomic <- mkSizedFIFOF(qpNum);
    // // FIFOF#(RKEY) rkeyQ4Send   <- mkSizedFIFOF(qpNum);
    // FIFOF#(RKEY) rkeyQ4Write  <- mkSizedFIFOF(qpNum);
    // FIFOF#(RKEY) rkeyQ4Read   <- mkSizedFIFOF(qpNum);
    // FIFOF#(RKEY) rkeyQ4Atomic <- mkSizedFIFOF(qpNum);

    let lkeyVecPipeOut4Recv   <- mkVector2PipeOut(readVReg(lkeyVec4Recv), lkeyVecValidReg);
    let lkeyVecPipeOut4Send   <- mkVector2PipeOut(readVReg(lkeyVec4Send), lkeyVecValidReg);
    let lkeyVecPipeOut4Write  <- mkVector2PipeOut(readVReg(lkeyVec4Write), lkeyVecValidReg);
    let lkeyVecPipeOut4Read   <- mkVector2PipeOut(readVReg(lkeyVec4Read), lkeyVecValidReg);
    let lkeyVecPipeOut4Atomic <- mkVector2PipeOut(readVReg(lkeyVec4Atomic), lkeyVecValidReg);
    // let rkeyVecPipeOut4Send   <- mkVector2PipeOut(readVReg(rkeyVec4Send), rkeyVecValidReg);
    let rkeyVecPipeOut4Write  <- mkVector2PipeOut(readVReg(rkeyVec4Write), rkeyVecValidReg);
    let rkeyVecPipeOut4Read   <- mkVector2PipeOut(readVReg(rkeyVec4Read), rkeyVecValidReg);
    let rkeyVecPipeOut4Atomic <- mkVector2PipeOut(readVReg(rkeyVec4Atomic), rkeyVecValidReg);

    FIFOF#(QPN)     qpnQ4Out <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)    qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4RTR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4RTS <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4ERR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN) qpnQ4Destroy <- mkSizedFIFOF(qpNum);

    FIFOF#(QPN)   sqpnQ4Recv <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))   sqpnQ4Send <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))  sqpnQ4Write <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))   sqpnQ4Read <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN)) sqpnQ4Atomic <- mkSizedFIFOF(qpNum);

    FIFOF#(Tuple2#(QPN, WorkReqID)) workReqIdQ4Cmp <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(Tuple2#(QPN, WorkReqID)) recvReqIdQ4Cmp <- mkSizedFIFOF(valueOf(MAX_QP));
    Vector#(MAX_QP, Reg#(WorkComp)) workCompVec4WorkReq <- replicateM(mkRegU);
    Vector#(MAX_QP, Reg#(WorkComp)) workCompVec4RecvReq <- replicateM(mkRegU);

    PipeOut#(KeyPD)     pdKeyPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD)))) pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))          pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_MR)))) mrReqCnt <- mkCount(fromInteger(mrNum));
    Count#(Bit#(TLog#(MAX_MR)))          mrRespCnt <- mkCount(fromInteger(mrNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))          qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    // Count#(Bit#(TLog#(MAX_MR_PER_PD)))  mrReqPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));
    // Count#(Bit#(TLog#(MAX_MR_PER_PD))) mrRespPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));
    // Count#(Bit#(TLog#(avgMrPerQP)))    mrRespPerQpCnt <- mkCount(fromInteger(mrPerQP - 1));
    // Count#(Bit#(TLog#(avgQpPerPD)))        qpPerPdCnt <- mkCount(fromInteger(qpPerPD - 1));

    Reg#(InitMetaDataState) initMetaDataStateReg <- mkReg(META_DATA_ALLOC_PD);

    ADDR defaultAddr   = fromInteger(0);
    Length defaultLen  = fromInteger(valueOf(RDMA_MAX_LEN));
    let defaultAccPerm =
        enum2Flag(IBV_ACCESS_LOCAL_WRITE)  |
        enum2Flag(IBV_ACCESS_REMOTE_WRITE) |
        enum2Flag(IBV_ACCESS_REMOTE_READ)  |
        enum2Flag(IBV_ACCESS_REMOTE_ATOMIC);
    let invalidAccPerm = enum2Flag(IBV_ACCESS_NO_FLAGS);

    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IMM) immDtPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rkey2InvPipeOut <- mkGenericRandomPipeOut;
    let dmaLenPipeOut <- mkRandomLenPipeOut(minDmaLength, maxDmaLength);

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 10)));

    function ActionValue#(WorkReq) genWorkReq(
        WorkReqOpCode wrOpCode,
        Bool needResp,
        QPN sqpn,
        QPN dqpn,
        LKEY lkey,
        RKEY rkey,
        ADDR laddr,
        ADDR raddr
    );
        actionvalue
            let wrID = workReqIdPipeOut.first;
            workReqIdPipeOut.deq;

            let dmaLen = dmaLenPipeOut.first;
            dmaLenPipeOut.deq;

            let isAtomicWR = isAtomicWorkReq(wrOpCode);

            let comp = compPipeOut.first;
            compPipeOut.deq;

            let swap = swapPipeOut.first;
            swapPipeOut.deq;

            let immDt = immDtPipeOut.first;
            immDtPipeOut.deq;

            let rkey2Inv = rkey2InvPipeOut.first;
            rkey2InvPipeOut.deq;

            let workReq = WorkReq {
                id       : wrID,
                opcode   : wrOpCode,
                flags    : needResp ? enum2Flag(IBV_SEND_SIGNALED) : enum2Flag(IBV_SEND_NO_FLAGS),
                raddr    : raddr,
                rkey     : rkey,
                len      : isAtomicWR ? fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)) : dmaLen,
                laddr    : laddr,
                lkey     : lkey,
                sqpn     : sqpn,
                solicited: False,
                comp     : workReqHasComp(wrOpCode) ? (tagged Valid comp) : (tagged Invalid),
                swap     : workReqHasSwap(wrOpCode) ? (tagged Valid swap) : (tagged Invalid),
                immDt    : workReqHasImmDt(wrOpCode) ? (tagged Valid immDt) : (tagged Invalid),
                rkey2Inv : workReqHasInv(wrOpCode) ? (tagged Valid rkey2Inv) : (tagged Invalid),
                srqn     : qpType == IBV_QPT_XRC_SEND ? (tagged Valid dqpn) : (tagged Invalid),
                dqpn     : qpType == IBV_QPT_UD ? (tagged Valid dqpn) : (tagged Invalid),
                qkey     : tagged Invalid
            };

            return workReq;
        endactionvalue
    endfunction

    function Rules issueWorkReqAndCheckWorkComp(
        WorkReqOpCode wrOpCode,
        Bool needResp,
        FIFOF#(Tuple2#(QPN, QPN)) qpnSrcDstPipeOut,
        PipeOut#(LKEY) lkeyPipeIn,
        PipeOut#(RKEY) rkeyPipeIn,
        InitMetaDataState issueState,
        InitMetaDataState checkState,
        InitMetaDataState nextState
    );
        let needCheckResp = needResp || isReadOrAtomicWorkReq(wrOpCode);

        return (rules
            rule issueWorkReq if (initMetaDataStateReg == issueState);
                if (isZero(qpRespCnt)) begin
                    qpReqCnt  <= fromInteger(qpNum);
                    qpRespCnt <= fromInteger(qpNum - 1);
                    initMetaDataStateReg <= needCheckResp ? checkState : nextState;
                end
                else begin
                    qpRespCnt.decr(1);
                end

                let { sqpn, dqpn } = qpnSrcDstPipeOut.first;
                qpnSrcDstPipeOut.deq;
                let lkey = lkeyPipeIn.first;
                lkeyPipeIn.deq;
                let rkey = rkeyPipeIn.first;
                rkeyPipeIn.deq;
                let laddr = defaultAddr;
                let raddr = defaultAddr;

                let wr <- genWorkReq(
                    wrOpCode, needResp, sqpn, dqpn,
                    lkey, rkey, laddr, raddr
                );

                transportLayer.workReqInput.put(wr);
                if (needCheckResp) begin
                    workReqIdQ4Cmp.enq(tuple2(sqpn, wr.id));
                end
                $display(
                    "time=%0t: issueWorkReq", $time,
                    ", wrOpCode=", fshow(wrOpCode),
                    ", sqpn=%h, dqpn=%h, lkey=%h, rkey=%h, wr.id=%h, wr.len=%0d",
                    sqpn, dqpn, lkey, rkey, wr.id, wr.len
                );
            endrule

            rule collectWorkComp4SendSide if (
                !isZero(qpReqCnt) && initMetaDataStateReg == checkState
            );
                qpReqCnt.decr(1);

                let wc = transportLayer.workCompPipeOutSQ.first;
                transportLayer.workCompPipeOutSQ.deq;

                let qpIndex = getIndexQP(wc.qpn);
                workCompVec4WorkReq[qpIndex] <= wc;
                // $display(
                //     "time=%0t: collectWorkComp4SendSide", $time,
                //     ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
                //     ", wc.opcode=", fshow(wc.opcode),
                //     ", wc.status=", fshow(wc.status)
                // );
            endrule

            rule compareReadWorkComp4SendSide if (
                isZero(qpReqCnt) && initMetaDataStateReg == checkState
            );
                if (isZero(qpRespCnt)) begin
                    qpReqCnt  <= fromInteger(qpNum);
                    qpRespCnt <= fromInteger(qpNum - 1);
                    initMetaDataStateReg <= nextState;
                end
                else begin
                    qpRespCnt.decr(1);
                end

                let { sqpn4SQ, expectedWorkCompID } = workReqIdQ4Cmp.first;
                workReqIdQ4Cmp.deq;

                let qpIndex = getIndexQP(sqpn4SQ);
                let wc = workCompVec4WorkReq[qpIndex];

                immAssert(
                    wc.id == expectedWorkCompID,
                    "WC ID for send WR assertion @ mkInitMetaData",
                    $format(
                        "wc.id=%h should == expectedWorkCompID=%h",
                        wc.id, expectedWorkCompID,
                        ", when wrOpCode=", fshow(wrOpCode)
                    )
                );

                let expectedWorkCompStatus = normalOrErrCase ?
                    IBV_WC_SUCCESS : IBV_WC_REM_ACCESS_ERR;
                immAssert(
                    wc.status == expectedWorkCompStatus,
                    "WC status assertion @ mkInitMetaData",
                    $format(
                        "wc.status=", fshow(wc.status),
                        " should be expectedWorkCompStatus=",
                        fshow(expectedWorkCompStatus)
                    )
                );
            endrule
        endrules);
    endfunction

    rule reqAllocPDs if (
        !isZero(pdReqCnt) && initMetaDataStateReg == META_DATA_ALLOC_PD
    );
        pdReqCnt.decr(1);
        let pdKey = pdKeyPipeOut.first;
        pdKeyPipeOut.deq;

        let allocReqPD = ReqPD {
            allocOrNot: True,
            pdKey     : pdKey,
            pdHandler : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4PD allocReqPD);

        // $display("time=%0t: pdKey=%h, pdReqCnt=%0d", $time, pdKey, pdReqCnt);
    endrule

    rule respAllocPDs if (initMetaDataStateReg == META_DATA_ALLOC_PD);
        if (isZero(pdRespCnt)) begin
            initMetaDataStateReg <= META_DATA_ALLOC_MR;
            pdHandlerVecValidReg <= True;
        end
        else begin
            pdRespCnt.decr(1);
        end

        let maybeAllocRespPD <- metaDataSrv.response.get;
        if (maybeAllocRespPD matches tagged Resp4PD .allocRespPD) begin
            immAssert(
                allocRespPD.successOrNot,
                "allocRespPD.successOrNot assertion @ mkInitMetaData",
                $format(
                    "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            pdHandlerVec4ReqMR[pdRespCnt] <= allocRespPD.pdHandler;
            pdHandlerVec4ReqQP[pdRespCnt] <= allocRespPD.pdHandler;
        end
        else begin
            immFail(
                "maybeAllocRespPD assertion @ mkInitMetaData",
                $format(
                    "maybeAllocRespPD=", fshow(maybeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end

        // $display("time=%0t: pdRespCnt=%0d", $time, pdRespCnt);
    endrule

    rule allocMRs if (
        !isZero(mrReqCnt) && initMetaDataStateReg == META_DATA_ALLOC_MR
    );
        mrReqCnt.decr(1);

        // if (isZero(mrReqPerPdCnt)) begin
        //     mrReqPerPdCnt <= fromInteger(mrPerPD - 1);
        // end
        // else begin
        //     mrReqPerPdCnt.decr(1);
        // end

        let pdHandler = pdHandlerPipeOut4ReqMR.first;
        pdHandlerPipeOut4ReqMR.deq;
        pdHandlerQ4RespMR.enq(pdHandler);

        let mrKey = mrKeyPipeOut.first;
        mrKeyPipeOut.deq;

        let allocReqMR = ReqMR {
            allocOrNot: True,
            mr: MemRegion {
                laddr    : defaultAddr,
                len      : defaultLen,
                accFlags : normalOrErrCase ? defaultAccPerm : invalidAccPerm,
                pdHandler: pdHandler,
                lkeyPart : mrKey,
                rkeyPart : mrKey
            },
            lkeyOrNot: False,
            rkey     : dontCareValue,
            lkey     : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4MR allocReqMR);

        // $display("time=%0t: mrKey=%h, mrReqCnt=%0d", $time, mrKey, mrReqCnt);
    endrule

    rule respAllocMRs if (initMetaDataStateReg == META_DATA_ALLOC_MR);
        if (isZero(mrRespCnt)) begin
            initMetaDataStateReg <= META_DATA_CREATE_QP;
            lkeyVecValidReg      <= isSendSideQ;
            rkeyVecValidReg      <= !isSendSideQ;
        end
        else begin
            mrRespCnt.decr(1);
        end

        // if (isZero(mrRespPerPdCnt)) begin
        //     mrRespPerPdCnt <= fromInteger(mrPerPD - 1);
        //     // pdHandlerQ4RespMR.deq;
        // end
        // else begin
        //     mrRespPerPdCnt.decr(1);
        // end

        // if (isZero(mrRespPerQpCnt)) begin
        //     mrRespPerQpCnt <= fromInteger(mrPerQP - 1);
        // end
        // else begin
        //     mrRespPerQpCnt.decr(1);
        // end

        let pdHandler = pdHandlerQ4RespMR.first;
        pdHandlerQ4RespMR.deq;

        let maybeAllocRespMR <- metaDataSrv.response.get;
        if (maybeAllocRespMR matches tagged Resp4MR .allocRespMR) begin
            immAssert(
                allocRespMR.successOrNot,
                "allocRespMR.successOrNot assertion @ mkInitMetaData",
                $format(
                    "allocRespMR.successOrNot=", fshow(allocRespMR.successOrNot),
                    " should be true when mrRespCnt=%0d", mrRespCnt
                )
            );

            // let showMR = True;
            Tuple2#(
                Bit#(TLog#(RDMA_REQ_TYPE_NUM)), Bit#(TSub#(TLog#(MAX_MR), TLog#(RDMA_REQ_TYPE_NUM)))
            ) pair = split(mrRespCnt);
            let { reqTypeIdx, vecIdx } = pair;
            case (reqTypeIdx)
                0: begin
                    if (isSendSideQ) begin
                        lkeyVec4Send[vecIdx] <= allocRespMR.lkey;
                        // rkeyVec4Send[vecIdx] <= allocRespMR.rkey;
                    end
                    else begin
                        lkeyVec4Recv[vecIdx] <= allocRespMR.lkey;
                    end
                end
                1: begin
                    if (isSendSideQ) begin
                        lkeyVec4Write[vecIdx] <= allocRespMR.lkey;
                    end
                    else begin
                        rkeyVec4Write[vecIdx] <= allocRespMR.rkey;
                    end
                end
                2: begin
                    if (isSendSideQ) begin
                        lkeyVec4Read[vecIdx] <= allocRespMR.lkey;
                    end
                    else begin
                        rkeyVec4Read[vecIdx] <= allocRespMR.rkey;
                    end
                end
                3: begin
                    if (isSendSideQ) begin
                        lkeyVec4Atomic[vecIdx] <= allocRespMR.lkey;
                    end
                    else begin
                        rkeyVec4Atomic[vecIdx] <= allocRespMR.rkey;
                    end
                end
                // 0: begin
                //     if (isSendSideQ) begin
                //         lkeyQ4Send.enq(allocRespMR.lkey);
                //         // rkeyQ4Send.enq(allocRespMR.rkey);
                //     end
                //     else begin
                //         lkeyQ4Recv.enq(allocRespMR.lkey);
                //     end
                // end
                // 1: begin
                //     if (isSendSideQ) begin
                //         lkeyQ4Write.enq(allocRespMR.lkey);
                //     end
                //     else begin
                //         rkeyQ4Write.enq(allocRespMR.rkey);
                //     end
                // end
                // 2: begin
                //     if (isSendSideQ) begin
                //         lkeyQ4Read.enq(allocRespMR.lkey);
                //     end
                //     else begin
                //         rkeyQ4Read.enq(allocRespMR.rkey);
                //     end
                // end
                // 3: begin
                //     if (isSendSideQ) begin
                //         lkeyQ4Atomic.enq(allocRespMR.lkey);
                //     end
                //     else begin
                //         rkeyQ4Atomic.enq(allocRespMR.rkey);
                //     end
                // end
                default: begin
                    // showMR = False;
                    immFail(
                        "reqTypeIdx assertion @ mkInitMetaData",
                        $format(
                            "reqTypeIdx=%0d should be 0 ~ 3", reqTypeIdx
                        )
                    );
                end
            endcase

            // if (showMR) begin
            $display(
                "time=%0d: respAllocMRs", $time,
                ", pdHandler=%h, allocRespMR.lkey=%h, allocRespMR.rkey=%h, vecIdx=%0d, reqTypeIdx=%0d",
                pdHandler, allocRespMR.lkey, allocRespMR.rkey, vecIdx, reqTypeIdx,
                ", isSendSideQ=", fshow(isSendSideQ)
            );
            // end
        end
        else begin
            immFail(
                "maybeAllocRespMR assertion @ mkInitMetaData",
                $format(
                    "maybeAllocRespMR=", fshow(maybeAllocRespMR),
                    " should be Resp4MR"
                )
            );
        end

        // $display("time=%0t: mrRespCnt=%0d", $time, mrRespCnt);
    endrule

    rule reqCreateQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CREATE_QP
    );
        qpReqCnt.decr(1);

        // if (isZero(qpPerPdCnt)) begin
        //     qpPerPdCnt <= fromInteger(qpPerPD - 1);
        // end
        // else begin
        //     qpPerPdCnt.decr(1);
        // end

        let pdHandler = pdHandlerPipeOut4ReqQP.first;
        pdHandlerPipeOut4ReqQP.deq;
        pdHandlerQ4RespQP.enq(pdHandler);

        let createReqQP = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : pdHandler,
            qpn       : dontCareValue,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);

        if (isSendSideQ) begin
        $display(
            "time=%0t: reqCreateQPs", $time,
            ", pdHandler=%h, qpReqCnt=%0d", pdHandler, qpReqCnt,
            ", isSendSideQ=", fshow(isSendSideQ)
        );
        end

        // $display(
        //     "time=%0t: reqCreateQPs", $time,
        //     ", pdHandlerQ4RespQP.notFull", fshow(pdHandlerQ4RespQP.notFull),
        //     ", qpnQ4Out.notFull=", fshow(qpnQ4Out.notFull),
        //     ", qpnQ4Init.notFull=", fshow(qpnQ4Init.notFull),
        //     ", qpnQ4RTR.notFull=", fshow(qpnQ4RTR.notFull),
        //     ", qpnQ4RTS.notFull=", fshow(qpnQ4RTS.notFull),
        //     ", qpnQ4ERR.notFull=", fshow(qpnQ4ERR.notFull),
        //     ", qpnQ4Destroy.notFull=", fshow(qpnQ4Destroy.notFull),
        //     ", sqpnQ4Recv.notFull=", fshow(sqpnQ4Recv.notFull),
        //     ", sqpnQ4Send.notFull=", fshow(sqpnQ4Send.notFull),
        //     ", sqpnQ4Write.notFull=", fshow(sqpnQ4Write.notFull),
        //     ", sqpnQ4Read.notFull=", fshow(sqpnQ4Read.notFull),
        //     ", sqpnQ4Atomic.notFull=", fshow(sqpnQ4Atomic.notFull)
        // );
        // $display(
        //     "time=%0t: reqCreateQPs", $time,
        //     ", pdHandlerQ4RespQP.notEmpty=", fshow(pdHandlerQ4RespQP.notEmpty),
        //     ", qpnQ4Out.notEmpty=", fshow(qpnQ4Out.notEmpty),
        //     ", qpnQ4Init.notEmpty=", fshow(qpnQ4Init.notEmpty),
        //     ", qpnQ4RTR.notEmpty=", fshow(qpnQ4RTR.notEmpty),
        //     ", qpnQ4RTS.notEmpty=", fshow(qpnQ4RTS.notEmpty),
        //     ", qpnQ4ERR.notEmpty=", fshow(qpnQ4ERR.notEmpty),
        //     ", qpnQ4Destroy.notEmpty=", fshow(qpnQ4Destroy.notEmpty),
        //     ", sqpnQ4Recv.notEmpty=", fshow(sqpnQ4Recv.notEmpty),
        //     ", sqpnQ4Send.notEmpty=", fshow(sqpnQ4Send.notEmpty),
        //     ", sqpnQ4Write.notEmpty=", fshow(sqpnQ4Write.notEmpty),
        //     ", sqpnQ4Read.notEmpty=", fshow(sqpnQ4Read.notEmpty),
        //     ", sqpnQ4Atomic.notEmpty=", fshow(sqpnQ4Atomic.notEmpty)
        // );
    endrule

    rule respCreateQPs if (initMetaDataStateReg == META_DATA_CREATE_QP);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_INIT_QP;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4RespQP.first;
        pdHandlerQ4RespQP.deq;

        let maybeCreateRespQP <- metaDataSrv.response.get;
        if (maybeCreateRespQP matches tagged Resp4QP .createRespQP) begin
            immAssert(
                createRespQP.successOrNot,
                "createRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "createRespQP.successOrNot=", fshow(createRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = createRespQP.qpn;
            qpnQ4Out.enq(qpn);
            qpnQ4Init.enq(qpn);
            qpnQ4RTR.enq(qpn);
            // qpnQ4RTS.enq(qpn);
            qpnQ4ERR.enq(qpn);
            qpnQ4Destroy.enq(qpn);

            // let maybeHandlerPD = transportLayer.getPD(qpn);
            // immAssert(
            //     isValid(maybeHandlerPD),
            //     "PD valid assertion @ mkInitMetaData",
            //     $format(
            //         "isValid(maybeHandlerPD)=", fshow(isValid(maybeHandlerPD)),
            //         " should be valid, when qpType=", fshow(createRespQP.qpInitAttr.qpType),
            //         " and qpn=%h", qpn
            //     )
            // );
            // $display(
            //     "time=%0t: maybeHandlerPD=", $time, fshow(maybeHandlerPD),
            //     " should be valid, when pdHandler=%h, qpn=%h, qpRespCnt=%h",
            //     pdHandler, qpn, qpRespCnt
            // );

            immAssert(
                createRespQP.pdHandler == pdHandler,
                "HandlerPD assertion @ mkInitMetaData",
                $format(
                    "createRespQP.pdHandler=%h should == pdHandler=%h",
                    createRespQP.pdHandler, pdHandler
                )
            );

            if (isSendSideQ) begin
            $display(
                "time=%0t: createRespQP=", $time, fshow(createRespQP),
                " should be success, when pdHandler=%h qpn=%h, qpRespCnt=%h",
                pdHandler, qpn, qpRespCnt,
                ", isSendSideQ=", fshow(isSendSideQ)
            );
            end
        end
        else begin
            immFail(
                "maybeCreateRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeCreateRespQP=", fshow(maybeCreateRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqInitQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_INIT_QP
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Init.first;
        qpnQ4Init.deq;

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let initReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP initReqQP);

        if (isSendSideQ) begin
        $display(
            "time=%0t: reqInitQPs", $time,
            ", qpReqCnt=%0d", qpReqCnt,
            ", isSendSideQ=", fshow(isSendSideQ)
        );
        end
    endrule

    rule respInitQPs if (initMetaDataStateReg == META_DATA_INIT_QP);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_SET_QP_RTR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeInitRespQP <- metaDataSrv.response.get;
        if (maybeInitRespQP matches tagged Resp4QP .initRespQP) begin
            immAssert(
                initRespQP.successOrNot,
                "initRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "initRespQP.successOrNot=", fshow(initRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );
            let qpn = initRespQP.qpn;
            // qpnQ4RTR.enq(qpn);

            if (isSendSideQ) begin
            $display(
                "time=%0t: initRespQP=", $time, fshow(initRespQP),
                " should be success, and qpn=%h, qpRespCnt=%h", qpn, qpRespCnt,
                ", isSendSideQ=", fshow(isSendSideQ)
            );
            end
        end
        else begin
            immFail(
                "maybeInitRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeInitRespQP=", fshow(maybeInitRespQP),
                    " should be Resp4QP"
                )
            );
        end

        if (isSendSideQ) begin
        $display(
            "time=%0t: respInitQPs", $time,
            ", qpnQ4RTR.notEmpty=", fshow(qpnQ4RTR.notEmpty),
            ", dqpnPipeIn.notEmpty=", fshow(dqpnPipeIn.notEmpty),
            ", isSendSideQ=", fshow(isSendSideQ)
        );
        end
    endrule

    rule reqRtrQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_RTR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4RTR.first;
        qpnQ4RTR.deq;

        let qpAttr = qpAttrPipeOut.first;

        let dqpn = dqpnPipeIn.first;
        dqpnPipeIn.deq;

        qpAttr.dqpn = dqpn;
        qpAttr.qpState = IBV_QPS_RTR;
        let setRtrReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP setRtrReqQP);

        if (isSendSideQ) begin
        $display(
            "time=%0t: reqRtrQPs", $time,
            ", qpReqCnt=%0d", qpReqCnt,
            ", isSendSideQ=", fshow(isSendSideQ)
        );
        end
    endrule

    rule respRtrQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            if (isSendSideQ) begin
                initMetaDataStateReg <= META_DATA_SET_QP_RTS;
            end
            else begin
                initMetaDataStateReg <= META_DATA_SEND_RR;
            end
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setRtrRespQP) begin
            immAssert(
                setRtrRespQP.successOrNot,
                "setRtrRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "setRtrRespQP.successOrNot=", fshow(setRtrRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setRtrRespQP=", fshow(setRtrRespQP)
                )
            );

            let sqpn = setRtrRespQP.qpn;
            let dqpn = setRtrRespQP.qpAttr.dqpn;

            if (isSendSideQ) begin
                qpnQ4RTS.enq(sqpn);

                sqpnQ4Send.enq(tuple2(sqpn, dqpn));
                sqpnQ4Write.enq(tuple2(sqpn, dqpn));
                sqpnQ4Read.enq(tuple2(sqpn, dqpn));
                sqpnQ4Atomic.enq(tuple2(sqpn, dqpn));
            end
            else begin
                sqpnQ4Recv.enq(sqpn);
            end

            if (isSendSideQ) begin
            $display(
                "time=%0t: setRtrRespQP=", $time, fshow(setRtrRespQP),
                " should be success, and sqpn=%h, dqpn=%h, qpRespCnt=%0d",
                sqpn, dqpn, qpRespCnt,
                ", isSendSideQ=", fshow(isSendSideQ)
            );
            end
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqRtsQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_RTS
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4RTS.first;
        qpnQ4RTS.deq;

        let qpAttr = qpAttrPipeOut.first;
        // qpAttrPipeOut.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let setRtsReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP setRtsReqQP);

        if (isSendSideQ) begin
        $display("time=%0t: reqRtsQPs, qpReqCnt=%0d", $time, qpReqCnt);
        end
    endrule

    rule respRtsQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTS);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= normalOrErrCase ? META_DATA_ATOMIC_WR : META_DATA_SEND_WR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setRtsRespQP) begin
            immAssert(
                setRtsRespQP.successOrNot,
                "setRtsRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "setRtsRespQP.successOrNot=", fshow(setRtsRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setRtsRespQP=", fshow(setRtsRespQP)
                )
            );
            // let qpn = setRtsRespQP.qpn;
            // qpnQ4Destroy.enq(qpn);

            if (isSendSideQ) begin
            $display(
                "time=%0t: setRtsRespQP=", $time, fshow(setRtsRespQP),
                " should be success, and setRtsRespQP.qpn=%h, qpRespCnt=%h",
                setRtsRespQP.qpn, qpRespCnt,
                ", isSendSideQ=", fshow(isSendSideQ)
            );
            end
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    if (isSendSideQ) begin
        let needAtomicResp = True;
        addRules(
            issueWorkReqAndCheckWorkComp(
                IBV_WR_ATOMIC_CMP_AND_SWP,
                needAtomicResp,
                sqpnQ4Atomic,
                lkeyVecPipeOut4Atomic,
                rkeyPipeIn4Atomic,
                META_DATA_ATOMIC_WR,
                META_DATA_CHECK_ATOMIC_WC,
                META_DATA_READ_WR
            )
        );

        let needReadResp = True;
        addRules(
            issueWorkReqAndCheckWorkComp(
                IBV_WR_RDMA_READ,
                needReadResp,
                sqpnQ4Read,
                lkeyVecPipeOut4Read,
                rkeyPipeIn4Read,
                META_DATA_READ_WR,
                META_DATA_CHECK_READ_WC,
                META_DATA_WRITE_WR
            )
        );

        let needWriteResp = False;
        addRules(
            issueWorkReqAndCheckWorkComp(
                IBV_WR_RDMA_WRITE,
                needWriteResp,
                sqpnQ4Write,
                lkeyVecPipeOut4Write,
                rkeyPipeIn4Write,
                META_DATA_WRITE_WR,
                META_DATA_CHECK_WRITE_WC,
                META_DATA_SEND_WR
            )
        );

        PipeOut#(RKEY) rkeyPipeIn4Send <- mkConstantPipeOut(dontCareValue);
        let needSendResp = True;
        addRules(
            issueWorkReqAndCheckWorkComp(
                IBV_WR_SEND_WITH_IMM,
                needSendResp,
                sqpnQ4Send,
                lkeyVecPipeOut4Send,
                rkeyPipeIn4Send,
                META_DATA_SEND_WR,
                META_DATA_CHECK_SEND_WC,
                normalOrErrCase ? META_DATA_SET_QP_ERR : META_DATA_DESTROY_QP
            )
        );
    end
    else begin
        rule issueRecvReq if (initMetaDataStateReg == META_DATA_SEND_RR);
            if (isZero(qpRespCnt)) begin
                qpReqCnt  <= fromInteger(qpNum);
                qpRespCnt <= fromInteger(qpNum - 1);
                initMetaDataStateReg <= META_DATA_CHECK_RR;
            end
            else begin
                qpRespCnt.decr(1);
            end

            let rrID = workReqIdPipeOut.first;
            workReqIdPipeOut.deq;
            let lkey4Recv = lkeyVecPipeOut4Recv.first;
            lkeyVecPipeOut4Recv.deq;
            let sqpn4RQ = sqpnQ4Recv.first;
            sqpnQ4Recv.deq;
            let rr = RecvReq {
                id   : rrID,
                len  : defaultLen,
                laddr: defaultAddr,
                lkey : lkey4Recv,
                sqpn : sqpn4RQ
            };

            // qpnQ4Destroy.enq(sqpn4RQ);
            transportLayer.recvReqInput.put(rr);
            recvReqIdQ4Cmp.enq(tuple2(sqpn4RQ, rrID));
            // $display(
            //     "time=%0t:", $time,
            //     " issueRecvReq, sqpn4RQ=%h, lkey4Recv=%h",
            //     sqpn4RQ, lkey4Recv
            // );
        endrule

        rule collectWorkComp4RecvSide if (
            !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_RR
        );
            qpReqCnt.decr(1);

            let wc = transportLayer.workCompPipeOutRQ.first;
            transportLayer.workCompPipeOutRQ.deq;

            let qpIndex = getIndexQP(wc.qpn);
            workCompVec4RecvReq[qpIndex] <= wc;
            // $display(
            //     "time=%0t: collectWorkComp4RecvSide", $time,
            //     ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
            //     ", wc.opcode=", fshow(wc.opcode),
            //     ", wc.status=", fshow(wc.status)
            // );
        endrule

        rule compareWorkComp4RecvSide if (
            isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_RR
        );
            if (isZero(qpRespCnt)) begin
                qpReqCnt  <= fromInteger(qpNum);
                qpRespCnt <= fromInteger(qpNum - 1);
                initMetaDataStateReg <= normalOrErrCase ? META_DATA_SET_QP_ERR : META_DATA_DESTROY_QP;
            end
            else begin
                qpRespCnt.decr(1);
            end

            let { sqpn4RQ, expectedWorkCompID } = recvReqIdQ4Cmp.first;
            recvReqIdQ4Cmp.deq;

            let qpIndex = getIndexQP(sqpn4RQ);
            let wc = workCompVec4RecvReq[qpIndex];

            immAssert(
                wc.id == expectedWorkCompID,
                "WC ID for RecvReq assertion @ mkInitMetaData",
                $format(
                    "wc.id=%h should == expectedWorkCompID=%h",
                    wc.id, expectedWorkCompID
                )
            );

            let expectedWorkCompStatus = normalOrErrCase ?
                IBV_WC_SUCCESS : IBV_WC_REM_ACCESS_ERR;
            immAssert(
                wc.status == expectedWorkCompStatus,
                "WC status assertion @ mkInitMetaData",
                $format(
                    "wc.status=", fshow(wc.status),
                    " should be expectedWorkCompStatus=",
                    fshow(expectedWorkCompStatus)
                )
            );
        endrule
    end

    rule reqErrQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_ERR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4ERR.first;
        qpnQ4ERR.deq;

        let qpAttr = qpAttrPipeOut.first;

        qpAttr.qpState = IBV_QPS_ERR;
        let setErrReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getOnlyStateRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP setErrReqQP);
        // $display(
        //     "time=%0t:", $time,
        //     " reqErrQP, qpReqCnt=%0d", qpReqCnt
        // );
    endrule

    rule respErrQPs if (initMetaDataStateReg == META_DATA_SET_QP_ERR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_DESTROY_QP;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setErrRespQP) begin
            immAssert(
                setErrRespQP.successOrNot,
                "setErrRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "setErrRespQP.successOrNot=", fshow(setErrRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setErrRespQP=", fshow(setErrRespQP)
                )
            );

            // $display(
            //     "time=%0t: setErrRespQP=", $time, fshow(setErrRespQP),
            //     " should be success, and setErrRespQP.qpn=%h, qpRespCnt=%h",
            //     setErrRespQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqDestroyQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_DESTROY_QP
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Destroy.first;
        qpnQ4Destroy.deq;

        let qpAttr = qpAttrPipeOut.first;
        // qpAttrPipeOut.deq;

        // qpAttr.qpState = IBV_QPS_RTS;
        let destroyReqQP = ReqQP {
            qpReqType : REQ_QP_DESTROY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: dontCareValue,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP destroyReqQP);
        if (isSendSideQ) begin
        $display(
            "time=%0t: reqDestroyQPs", $time,
            ", qpReqCnt=%0d", qpReqCnt,
            ", isSendSideQ=", fshow(isSendSideQ)
        );
        end
    endrule

    rule respDestroyQPs if (initMetaDataStateReg == META_DATA_DESTROY_QP);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_NO_OP;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .destroyRespQP) begin
            immAssert(
                destroyRespQP.successOrNot,
                "destroyRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "destroyRespQP.successOrNot=", fshow(destroyRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", destroyRespQP=", fshow(destroyRespQP)
                )
            );

            // $display(
            //     "time=%0t: destroyRespQP=", $time, fshow(destroyRespQP),
            //     " should be success, and destroyRespQP.qpn=%h, qpRespCnt=%h",
            //     destroyRespQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    // When nomal case, SQ will receive Send WC earlier than RQ,
    // since normal Send requests will generate ACK before DMA write.
    // When error case, RQ will receive Send WC earlier than SQ.
    rule loop if (initMetaDataStateReg == META_DATA_NO_OP);
        initMetaDataStateReg <= META_DATA_CREATE_QP;
        countDown.decr;

        // Clear all QP related queues
        qpnQ4Out.clear;
        qpnQ4Init.clear;
        qpnQ4RTR.clear;
        qpnQ4RTS.clear;
        qpnQ4ERR.clear;
        qpnQ4Destroy.clear;
        sqpnQ4Recv.clear;
        sqpnQ4Send.clear;
        sqpnQ4Write.clear;
        sqpnQ4Read.clear;
        sqpnQ4Atomic.clear;

        $display("time=%0t: loop, isSendSideQ=", $time, fshow(isSendSideQ));
    endrule
    // let waitCond = normalOrErrCase ? !isSendSideQ : isSendSideQ;
    // if (waitCond) begin
    //     rule done if (initMetaDataStateReg == META_DATA_NO_OP);
    //         normalExit;
    //     endrule
    // end

    interface qpnPipeOut         = toPipeOut(qpnQ4Out);
    // interface rkeyPipeOut4Send   = rkeyVecPipeOut4Send;
    interface rkeyPipeOut4Write  = rkeyVecPipeOut4Write;
    interface rkeyPipeOut4Read   = rkeyVecPipeOut4Read;
    interface rkeyPipeOut4Atomic = rkeyVecPipeOut4Atomic;
    // // interface rkeyPipeOut4Send   = toPipeOut(rkeyQ4Send);
    // interface rkeyPipeOut4Write  = toPipeOut(rkeyQ4Write);
    // interface rkeyPipeOut4Read   = toPipeOut(rkeyQ4Read);
    // interface rkeyPipeOut4Atomic = toPipeOut(rkeyQ4Atomic);
endmodule
