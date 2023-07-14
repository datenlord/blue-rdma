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
    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_RC; // IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;
    let isSendSideQ = True;

    FIFOF#(QPN) dqpnQ4RecvSide <- mkFIFOF;
    FIFOF#(QPN) dqpnQ4SendSide <- mkFIFOF;

    FIFOF#(RKEY) recvSideRKeyQ4Write  <- mkFIFOF;
    FIFOF#(RKEY) recvSideRKeyQ4Read   <- mkFIFOF;
    FIFOF#(RKEY) recvSideRKeyQ4Atomic <- mkFIFOF;
    FIFOF#(RKEY) sendSideRKeyQ4Write  <- mkFIFOF;
    FIFOF#(RKEY) sendSideRKeyQ4Read   <- mkFIFOF;
    FIFOF#(RKEY) sendSideRKeyQ4Atomic <- mkFIFOF;

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
        !isSendSideQ
    );
    let noWorkCompOutRule4RecvSideSendQ <- addRules(genEmptyPipeOutRule(
        recvSideTransportLayer.workCompPipeOutSQ,
        "recvSideTransportLayer.workCompPipeOutSQ empty assertion @ mkTestTransportLayerNormalCase"
    ));

    let simDmaReadSrv4RecvSide  <- mkSimDmaReadSrv;
    let simDmaWriteSrv4RecvSide <- mkSimDmaWriteSrv;
    mkConnection(recvSideTransportLayer.dmaReadClt, simDmaReadSrv4RecvSide);
    mkConnection(recvSideTransportLayer.dmaWriteClt, simDmaWriteSrv4RecvSide);

    let sendSideTransportLayer <- mkTransportLayer;
    let initSendSide <- mkInitMetaDataAndConnectQP(
        sendSideTransportLayer,
        toPipeOut(dqpnQ4SendSide),
        toPipeOut(sendSideRKeyQ4Write),
        toPipeOut(sendSideRKeyQ4Read),
        toPipeOut(sendSideRKeyQ4Atomic),
        minDmaLength,
        maxDmaLength,
        qpType,
        pmtu,
        isSendSideQ
    );
    let noWorkCompOutRule4SendSideRecvQ <- addRules(genEmptyPipeOutRule(
        sendSideTransportLayer.workCompPipeOutRQ,
        "sendSideTransportLayer.workCompPipeOutRQ empty assertion @ mkTestTransportLayerNormalCase"
    ));

    let simDmaReadSrv4SendSide  <- mkSimDmaReadSrv;
    let simDmaWriteSrv4SendSide <- mkSimDmaWriteSrv;
    mkConnection(sendSideTransportLayer.dmaReadClt, simDmaReadSrv4SendSide);
    mkConnection(sendSideTransportLayer.dmaWriteClt, simDmaWriteSrv4SendSide);

    mkConnection(
        toGet(sendSideTransportLayer.rdmaDataStreamPipeOut),
        recvSideTransportLayer.rdmaDataStreamInput
    );
    mkConnection(
        toGet(recvSideTransportLayer.rdmaDataStreamPipeOut),
        sendSideTransportLayer.rdmaDataStreamInput
    );

    rule popRecvSideQPN;
        let qpnRecvSide = initRecvSide.qpnPipeOut.first;
        initRecvSide.qpnPipeOut.deq;
        dqpnQ4SendSide.enq(qpnRecvSide);
    endrule

    rule popSendSideQPN;
        let qpnSendSide = initSendSide.qpnPipeOut.first;
        initSendSide.qpnPipeOut.deq;
        dqpnQ4RecvSide.enq(qpnSendSide);
    endrule

    rule popRecvSideWriteRKey;
        let rkey4Write = initRecvSide.rkeyPipeOut4Write.first;
        initRecvSide.rkeyPipeOut4Write.deq;
        sendSideRKeyQ4Write.enq(rkey4Write);
    endrule

    rule popRecvSideReadRKey;
        let rkey4Read = initRecvSide.rkeyPipeOut4Read.first;
        initRecvSide.rkeyPipeOut4Read.deq;
        sendSideRKeyQ4Read.enq(rkey4Read);
    endrule

    rule popRecvSideAtomicRKey;
        let rkey4Atomic = initRecvSide.rkeyPipeOut4Atomic.first;
        initRecvSide.rkeyPipeOut4Atomic.deq;
        sendSideRKeyQ4Atomic.enq(rkey4Atomic);
    endrule
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
    Bool isSendSideQ
)(InitMetaDataAndConnectQP) provisos(
    NumAlias#(TDiv#(MAX_QP, MAX_PD), avgQpPerPD),
    NumAlias#(TDiv#(MAX_MR_PER_PD, avgQpPerPD), avgMrPerQP),
    Add#(TMul#(avgMrPerQP, avgQpPerPD), 0, MAX_MR_PER_PD), // MAX_MR_PER_PD can be divided by avgQpPerPD
    Add#(4, anysize, avgMrPerQP) // avgMrPerQP should >= 4
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

    FIFOF#(HandlerPD)  pdHandlerQ4ReqMR <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD) pdHandlerQ4RespMR <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD)  pdHandlerQ4ReqQP <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD) pdHandlerQ4RespQP <- mkSizedFIFOF(qpNum);

    FIFOF#(LKEY) lkeyQ4Recv   <- mkSizedFIFOF(qpNum);
    FIFOF#(LKEY) lkeyQ4Send   <- mkSizedFIFOF(qpNum);
    FIFOF#(LKEY) lkeyQ4Write  <- mkSizedFIFOF(qpNum);
    FIFOF#(LKEY) lkeyQ4Read   <- mkSizedFIFOF(qpNum);
    FIFOF#(LKEY) lkeyQ4Atomic <- mkSizedFIFOF(qpNum);
    // FIFOF#(RKEY) rkeyQ4Send   <- mkSizedFIFOF(qpNum);
    FIFOF#(RKEY) rkeyQ4Write  <- mkSizedFIFOF(qpNum);
    FIFOF#(RKEY) rkeyQ4Read   <- mkSizedFIFOF(qpNum);
    FIFOF#(RKEY) rkeyQ4Atomic <- mkSizedFIFOF(qpNum);

    FIFOF#(QPN)     qpnQ4Out <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)    qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4RTR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4RTS <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN) qpnQ4Destroy <- mkSizedFIFOF(qpNum);

    FIFOF#(QPN)   sqpnQ4Recv <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))   sqpnQ4Send <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))  sqpnQ4Write <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN))   sqpnQ4Read <- mkSizedFIFOF(qpNum);
    FIFOF#(Tuple2#(QPN, QPN)) sqpnQ4Atomic <- mkSizedFIFOF(qpNum);

    FIFOF#(Tuple2#(QPN, WorkReqID)) workReqIdQ4Cmp <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(Tuple2#(QPN, WorkReqID)) recvReqIdQ4Cmp <- mkSizedFIFOF(valueOf(MAX_QP));
    Vector#(MAX_QP, Reg#(WorkComp)) workCompVec4SendWR <- replicateM(mkRegU);
    Vector#(MAX_QP, Reg#(WorkComp)) workCompVec4RecvReq <- replicateM(mkRegU);

    PipeOut#(KeyPD)     pdKeyPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))    pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))             pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_MR))))    mrReqCnt <- mkCount(fromInteger(mrNum));
    Count#(Bit#(TLog#(MAX_MR)))             mrRespCnt <- mkCount(fromInteger(mrNum - 1));
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))  mrReqPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));
    Count#(Bit#(TLog#(MAX_MR_PER_PD))) mrRespPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));
    Count#(Bit#(TLog#(avgMrPerQP))) mrRespPerQpCnt <- mkCount(fromInteger(mrPerQP - 1));

    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))  qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))           qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    Count#(Bit#(TLog#(avgQpPerPD)))   qpPerPdCnt <- mkCount(fromInteger(qpPerPD - 1));

    Reg#(InitMetaDataState) initMetaDataStateReg <- mkReg(META_DATA_ALLOC_PD);

    ADDR defaultAddr   = fromInteger(0);
    Length defaultLen  = fromInteger(valueOf(RDMA_MAX_LEN));
    let defaultAccPerm =
        enum2Flag(IBV_ACCESS_LOCAL_WRITE)  |
        enum2Flag(IBV_ACCESS_REMOTE_WRITE) |
        enum2Flag(IBV_ACCESS_REMOTE_READ)  |
        enum2Flag(IBV_ACCESS_REMOTE_ATOMIC);

    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IMM) immDtPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rkey2InvPipeOut <- mkGenericRandomPipeOut;
    let dmaLenPipeOut <- mkRandomLenPipeOut(minDmaLength, maxDmaLength);

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
        FIFOF#(LKEY) lkeyQ,
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
                let lkey = lkeyQ.first;
                lkeyQ.deq;
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
                    ", sqpn=%h, dqpn=%h", sqpn, dqpn
                );
            endrule

            rule collectWorkComp4SendSide if (
                !isZero(qpReqCnt) && initMetaDataStateReg == checkState
            );
                qpReqCnt.decr(1);

                let wc = transportLayer.workCompPipeOutSQ.first;
                transportLayer.workCompPipeOutSQ.deq;

                let qpIndex = getIndexQP(wc.qpn);
                workCompVec4SendWR[qpIndex] <= wc;
                $display(
                    "time=%0t: collectWorkComp4SendSide", $time,
                    ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
                    ", wc.opcode=", fshow(wc.opcode),
                    ", wc.status=", fshow(wc.status)
                );
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
                let wc = workCompVec4SendWR[qpIndex];

                immAssert(
                    wc.id == expectedWorkCompID,
                    "WC ID for send WR assertion @ mkInitMetaData",
                    $format(
                        "wc.id=%h should == expectedWorkCompID=%h",
                        wc.id, expectedWorkCompID,
                        ", when wrOpCode=", fshow(wrOpCode)
                    )
                );

                immAssert(
                    wc.status == IBV_WC_SUCCESS,
                    "WC status assertion @ mkInitMetaData",
                    $format(
                        "wc.status=", fshow(wc.status),
                        " should be success, when wrOpCode=", fshow(wrOpCode)
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

        // $display("time=%0t: pdKey=%h", $time, pdKey);
    endrule

    rule respAllocPDs if (initMetaDataStateReg == META_DATA_ALLOC_PD);
        if (isZero(pdRespCnt)) begin
            initMetaDataStateReg <= META_DATA_ALLOC_MR;
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
            pdHandlerQ4ReqMR.enq(allocRespPD.pdHandler);
            pdHandlerQ4RespMR.enq(allocRespPD.pdHandler);
            pdHandlerQ4ReqQP.enq(allocRespPD.pdHandler);
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

        if (isZero(mrReqPerPdCnt)) begin
            mrReqPerPdCnt <= fromInteger(mrPerPD - 1);
            pdHandlerQ4ReqMR.deq;
        end
        else begin
            mrReqPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4ReqMR.first;

        let mrKey = mrKeyPipeOut.first;
        mrKeyPipeOut.deq;

        let allocReqMR = ReqMR {
            allocOrNot: True,
            mr: MemRegion {
                laddr    : defaultAddr,
                len      : defaultLen,
                accFlags : defaultAccPerm,
                pdHandler: pdHandler,
                lkeyPart : mrKey,
                rkeyPart : mrKey
            },
            lkeyOrNot: False,
            rkey     : dontCareValue,
            lkey     : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4MR allocReqMR);

        // $display("time=%0t: mrKey=%h", $time, mrKey);
    endrule

    rule respAllocMRs if (initMetaDataStateReg == META_DATA_ALLOC_MR);
        if (isZero(mrRespCnt)) begin
            initMetaDataStateReg <= META_DATA_CREATE_QP;
        end
        else begin
            mrRespCnt.decr(1);
        end

        if (isZero(mrRespPerPdCnt)) begin
            mrRespPerPdCnt <= fromInteger(mrPerPD - 1);
            pdHandlerQ4RespMR.deq;
        end
        else begin
            mrRespPerPdCnt.decr(1);
        end

        if (isZero(mrRespPerQpCnt)) begin
            mrRespPerQpCnt <= fromInteger(mrPerQP - 1);
        end
        else begin
            mrRespPerQpCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4RespMR.first;

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

            case (mrRespPerQpCnt)
                0: begin
                    if (isSendSideQ) begin
                        lkeyQ4Send.enq(allocRespMR.lkey);
                        // rkeyQ4Send.enq(allocRespMR.rkey);
                    end
                    else begin
                        lkeyQ4Recv.enq(allocRespMR.lkey);
                    end
                end
                1: begin
                    if (isSendSideQ) begin
                        lkeyQ4Write.enq(allocRespMR.lkey);
                    end
                    else begin
                        rkeyQ4Write.enq(allocRespMR.rkey);
                    end
                end
                2: begin
                    if (isSendSideQ) begin
                        lkeyQ4Read.enq(allocRespMR.lkey);
                    end
                    else begin
                        rkeyQ4Read.enq(allocRespMR.rkey);
                    end
                end
                3: begin
                    if (isSendSideQ) begin
                        lkeyQ4Atomic.enq(allocRespMR.lkey);
                    end
                    else begin
                        rkeyQ4Atomic.enq(allocRespMR.rkey);
                    end
                end
                default: begin end
            endcase

            // if (mrRespPerQpCnt < 4) begin
            //     $display(
            //         "time=%0d:", $time,
            //         " pdHandler=%h, allocRespMR.lkey=%h, allocRespMR.rkey=%h",
            //         pdHandler, allocRespMR.lkey, allocRespMR.rkey
            //     );
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

        if (isZero(qpPerPdCnt)) begin
            qpPerPdCnt <= fromInteger(qpPerPD - 1);
            pdHandlerQ4ReqQP.deq;
        end
        else begin
            qpPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4ReqQP.first;

        let createReqQP = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : pdHandler,
            qpn       : dontCareValue,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
        pdHandlerQ4RespQP.enq(pdHandler);
        // $display(
        //     "time=%0t: reqCreateQPs", $time,
        //     ", pdHandler=%h qpPerPdCnt=%0d, qpReqCnt=%0d",
        //     pdHandler, qpPerPdCnt, qpReqCnt
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
            qpnQ4Init.enq(qpn);
            qpnQ4Out.enq(qpn);

            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, when pdHandler=%h qpn=%h, qpRespCnt=%h",
            //     pdHandler, qpn, qpRespCnt
            // );
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
            qpnQ4RTR.enq(qpn);
            // $display(
            //     "time=%0t: initRespQP=", $time, fshow(initRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     $time, qpn, qpRespCnt
            // );
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
        // $display(
        //     "time=%0t:", $time,
        //     " reqRtrQPs, qpReqCnt=%0d", qpReqCnt,
        //     ", isSendSideQ=", fshow(isSendSideQ)
        // );
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
            // $display(
            //     "time=%0t: setRtrRespQP=", $time, fshow(setRtrRespQP),
            //     " should be success, and setRtrRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtrRespQP.qpn, qpRespCnt
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
        // $display("time=%0t: reqRtsQPs, qpReqCnt=%0d", $time, qpReqCnt);
    endrule

    rule respRtsQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTS);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_ATOMIC_WR;
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

            let qpn = setRtsRespQP.qpn;
            qpnQ4Destroy.enq(qpn);
            // $display(
            //     "time=%0t: setRtsRespQP=", $time, fshow(setRtsRespQP),
            //     " should be success, and setRtsRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtsRespQP.qpn, qpRespCnt
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
/*
    rule issueAtomicWorkReq if (initMetaDataStateReg == META_DATA_ATOMIC_WR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_READ_WR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let wrOpCode = IBV_WR_ATOMIC_CMP_AND_SWP;
        let { sqpn4Atomic, dqpn4Atomic } = sqpnQ4Atomic.first;
        sqpnQ4Atomic.deq;
        let lkey4Atomic = lkeyQ4Atomic.first;
        lkeyQ4Atomic.deq;
        let rkey4Atomic = rkeyPipeIn4Atomic.first;
        rkeyPipeIn4Atomic.deq;
        let laddr4Atomic = defaultAddr;
        let raddr4Atomic = defaultAddr;
        let wr <- genWorkReq(
            wrOpCode,
            sqpn4Atomic,
            dqpn4Atomic,
            lkey4Atomic,
            rkey4Atomic,
            laddr4Atomic,
            raddr4Atomic
        );

        // workReqIdQ4Cmp.enq(tuple2(sqpn4Atomic, wr.id));
        $display("time=%0t: issueAtomicWorkReq, sqpn4Atomic=%h", $time, sqpn4Atomic);
    endrule

    rule issueReadWorkReq if (initMetaDataStateReg == META_DATA_READ_WR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_CHECK_READ_WC;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let wrOpCode = IBV_WR_RDMA_READ;
        let { sqpn4Read, dqpn4Read } = sqpnQ4Read.first;
        sqpnQ4Read.deq;
        let lkey4Read = lkeyQ4Read.first;
        lkeyQ4Read.deq;
        let rkey4Read = rkeyPipeIn4Read.first;
        rkeyPipeIn4Read.deq;
        let laddr4Read = defaultAddr;
        let raddr4Read = defaultAddr;
        let wr <- genWorkReq(
            wrOpCode,
            sqpn4Read,
            dqpn4Read,
            lkey4Read,
            rkey4Read,
            laddr4Read,
            raddr4Read
        );

        transportLayer.workReqInput.put(wr);
        workReqIdQ4Cmp.enq(tuple2(sqpn4Read, wr.id));
        $display("time=%0t: issueReadWorkReq, sqpn4Read=%h", $time, sqpn4Read);
    endrule

        rule collectReadWorkComp4SendSide if (
            !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_READ_WC
        );
            qpReqCnt.decr(1);

            let wc = transportLayer.workCompPipeOutSQ.first;
            transportLayer.workCompPipeOutSQ.deq;

            let qpIndex = getIndexQP(wc.qpn);
            workCompVec4SendWR[qpIndex] <= wc;
            $display(
                "time=%0t: collectReadWorkComp4SendSide", $time,
                ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
                ", wc.status=", fshow(wc.status)
            );
        endrule

        rule compareReadWorkComp4SendSide if (
            isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_READ_WC
        );
            if (isZero(qpRespCnt)) begin
                qpReqCnt  <= fromInteger(qpNum);
                qpRespCnt <= fromInteger(qpNum - 1);
                initMetaDataStateReg <= META_DATA_WRITE_WR;
            end
            else begin
                qpRespCnt.decr(1);
            end

            let { sqpn4SQ, expectedWorkCompID } = workReqIdQ4Cmp.first;
            workReqIdQ4Cmp.deq;

            let qpIndex = getIndexQP(sqpn4SQ);
            let wc = workCompVec4SendWR[qpIndex];

            immAssert(
                wc.id == expectedWorkCompID,
                "WC ID for send WR assertion @ mkInitMetaData",
                $format(
                    "wc.id=%h should == expectedWorkCompID=%h",
                    wc.id, expectedWorkCompID
                )
            );

            immAssert(
                wc.status == IBV_WC_SUCCESS,
                "WC status assertion @ mkInitMetaData",
                $format(
                    "wc.status=", fshow(wc.status),
                    " should be success"
                )
            );
        endrule

    rule issueWriteWorkReq if (initMetaDataStateReg == META_DATA_WRITE_WR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_SEND_WR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let wrOpCode = IBV_WR_RDMA_WRITE_WITH_IMM;
        let { sqpn4Write, dqpn4Write } = sqpnQ4Write.first;
        sqpnQ4Write.deq;
        let lkey4Write = lkeyQ4Write.first;
        lkeyQ4Write.deq;
        let rkey4Write = rkeyPipeIn4Write.first;
        rkeyPipeIn4Write.deq;
        let laddr4Write = defaultAddr;
        let raddr4Write = defaultAddr;
        let wr <- genWorkReq(
            wrOpCode,
            sqpn4Write,
            dqpn4Write,
            lkey4Write,
            rkey4Write,
            laddr4Write,
            raddr4Write
        );

        // workReqIdQ4Cmp.enq(tuple2(sqpn4Write, wr.id));
        $display("time=%0t: issueWriteWorkReq, sqpn4Write=%h", $time, sqpn4Write);
    endrule

    rule issueSendWorkReq if (initMetaDataStateReg == META_DATA_SEND_WR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_CHECK_SEND_WC;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let wrOpCode = IBV_WR_SEND_WITH_IMM;
        let { sqpn4Send, dqpn4Send } = sqpnQ4Send.first;
        sqpnQ4Send.deq;
        let lkey4Send = lkeyQ4Send.first;
        lkeyQ4Send.deq;
        let rkey4Send = dontCareValue;
        let laddr4Send = defaultAddr;
        let raddr4Send = dontCareValue;
        let needResp = True;
        let wr <- genWorkReq(
            wrOpCode,
            needResp,
            sqpn4Send,
            dqpn4Send,
            lkey4Send,
            rkey4Send,
            laddr4Send,
            raddr4Send
        );

        transportLayer.workReqInput.put(wr);
        workReqIdQ4Cmp.enq(tuple2(sqpn4Send, wr.id));
        $display("time=%0t: issueSendWorkReq, sqpn4Send=%h", $time, sqpn4Send);
    endrule

        rule collectSendWorkComp4SendSide if (
            !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_SEND_WC
        );
            qpReqCnt.decr(1);

            let wc = transportLayer.workCompPipeOutSQ.first;
            transportLayer.workCompPipeOutSQ.deq;

            let qpIndex = getIndexQP(wc.qpn);
            workCompVec4SendWR[qpIndex] <= wc;
            $display(
                "time=%0t: collectSendWorkComp4SendSide", $time,
                ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
                ", wc.status=", fshow(wc.status)
            );
        endrule

        rule compareSendWorkComp4SendSide if (
            isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_SEND_WC
        );
            if (isZero(qpRespCnt)) begin
                qpReqCnt  <= fromInteger(qpNum);
                qpRespCnt <= fromInteger(qpNum - 1);
                initMetaDataStateReg <= META_DATA_DESTROY_QP;
            end
            else begin
                qpRespCnt.decr(1);
            end

            let { sqpn4SQ, expectedWorkCompID } = workReqIdQ4Cmp.first;
            workReqIdQ4Cmp.deq;

            let qpIndex = getIndexQP(sqpn4SQ);
            let wc = workCompVec4SendWR[qpIndex];

            immAssert(
                wc.id == expectedWorkCompID,
                "WC ID for send WR assertion @ mkInitMetaData",
                $format(
                    "wc.id=%h should == expectedWorkCompID=%h",
                    wc.id, expectedWorkCompID
                )
            );

            immAssert(
                wc.status == IBV_WC_SUCCESS,
                "WC status assertion @ mkInitMetaData",
                $format(
                    "wc.status=", fshow(wc.status),
                    " should be success"
                )
            );
        endrule
*/
    if (isSendSideQ) begin
        let needAtomicResp = True;
        addRules(
            issueWorkReqAndCheckWorkComp(
                IBV_WR_ATOMIC_CMP_AND_SWP,
                needAtomicResp,
                sqpnQ4Atomic,
                lkeyQ4Atomic,
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
                lkeyQ4Read,
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
                lkeyQ4Write,
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
                lkeyQ4Send,
                rkeyPipeIn4Send,
                META_DATA_SEND_WR,
                META_DATA_CHECK_SEND_WC,
                META_DATA_DESTROY_QP
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
            let lkey4Recv = lkeyQ4Recv.first;
            lkeyQ4Recv.deq;
            let sqpn4RQ = sqpnQ4Recv.first;
            sqpnQ4Recv.deq;
            let rr = RecvReq {
                id   : rrID,
                len  : defaultLen,
                laddr: defaultAddr,
                lkey : lkey4Recv,
                sqpn : sqpn4RQ
            };

            transportLayer.recvReqInput.put(rr);
            recvReqIdQ4Cmp.enq(tuple2(sqpn4RQ, rrID));
            qpnQ4Destroy.enq(sqpn4RQ);
            $display(
                "time=%0t:", $time,
                " issueRecvReq, sqpn4RQ=%h, lkey4Recv=%h",
                sqpn4RQ, lkey4Recv
            );
        endrule

        rule collectWorkComp4RecvSide if (
            !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_RR
        );
            qpReqCnt.decr(1);

            let wc = transportLayer.workCompPipeOutRQ.first;
            transportLayer.workCompPipeOutRQ.deq;

            let qpIndex = getIndexQP(wc.qpn);
            workCompVec4RecvReq[qpIndex] <= wc;
            $display(
                "time=%0t: collectWorkComp4RecvSide", $time,
                ", qpIndex=%0d, wc.id=%h, wc.len=%0d", qpIndex, wc.id, wc.len,
                ", wc.opcode=", fshow(wc.opcode),
                ", wc.status=", fshow(wc.status)
            );
        endrule

        rule compareWorkComp4RecvSide if (
            isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CHECK_RR
        );
            if (isZero(qpRespCnt)) begin
                qpReqCnt  <= fromInteger(qpNum);
                qpRespCnt <= fromInteger(qpNum - 1);
                initMetaDataStateReg <= META_DATA_DESTROY_QP;
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

            immAssert(
                wc.status == IBV_WC_SUCCESS,
                "WC status assertion @ mkInitMetaData",
                $format(
                    "wc.status=", fshow(wc.status),
                    " should be success"
                )
            );
        endrule
    end

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
        $display("time=%0t: reqDestroyQPs, qpReqCnt=%0d", $time, qpReqCnt);
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
            //     $time, destroyRespQP.qpn, qpRespCnt
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

    if (isSendSideQ) begin
        rule done if (initMetaDataStateReg == META_DATA_NO_OP);
            normalExit;
        endrule
    end

    interface qpnPipeOut         = toPipeOut(qpnQ4Out);
    // interface rkeyPipeOut4Send   = toPipeOut(rkeyQ4Send);
    interface rkeyPipeOut4Write  = toPipeOut(rkeyQ4Write);
    interface rkeyPipeOut4Read   = toPipeOut(rkeyQ4Read);
    interface rkeyPipeOut4Atomic = toPipeOut(rkeyQ4Atomic);
endmodule
/*
module mkTestTransportLayer(Empty);
    let isSendSideQ = True;
    let sendSideTransportLayer <- mkTransportLayer;
    let initMetaDataSendSide <- mkInitMetaData(sendSideTransportLayer, isSendSideQ);

    let recvSideTransportLayer <- mkTransportLayer;
    let initMetaDataRecvSide <- mkInitMetaData(recvSideTransportLayer, !isSendSideQ);
endmodule

typedef enum {
    META_DATA_ALLOC_PD,
    META_DATA_ALLOC_MR,
    META_DATA_CREATE_QP,
    META_DATA_INIT_QP,
    META_DATA_SET_QP_RTR,
    META_DATA_SET_QP_RTS,
    META_DATA_DESTROY_QP,
    META_DATA_NO_OP
} InitMetaDataState deriving(Bits, Eq, FShow);

module mkInitMetaData#(TransportLayer transportLayer, Bool isSendSideQ)(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_512;

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
    let qpPerPD = valueOf(TDiv#(MAX_QP, MAX_PD));

    let metaDataSrv = transportLayer.srvPortMetaData;

    FIFOF#(HandlerPD)  pdHandlerQ4ReqMR <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD) pdHandlerQ4RespMR <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD)  pdHandlerQ4ReqQP <- mkSizedFIFOF(pdNum);
    FIFOF#(Tuple2#(HandlerPD, LKEY)) lKeyQ4Fill <- mkSizedFIFOF(mrNum);
    FIFOF#(Tuple2#(HandlerPD, RKEY)) rKeyQ4Fill <- mkSizedFIFOF(mrNum);
    FIFOF#(QPN)             qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)              qpnQ4RTR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)              qpnQ4RTS <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)          qpnQ4Destroy <- mkSizedFIFOF(qpNum);

    PipeOut#(KeyPD)     pdKeyPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))    pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))             pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_MR))))    mrReqCnt <- mkCount(fromInteger(mrNum));
    Count#(Bit#(TLog#(MAX_MR)))             mrRespCnt <- mkCount(fromInteger(mrNum - 1));
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))  mrReqPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));
    Count#(Bit#(TLog#(MAX_MR_PER_PD))) mrRespPerPdCnt <- mkCount(fromInteger(mrPerPD - 1));

    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))        qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))                 qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    Count#(Bit#(TLog#(TDiv#(MAX_QP, MAX_PD)))) qpPerPdCnt <- mkCount(fromInteger(qpPerPD - 1));

    Reg#(InitMetaDataState) initMetaDataStateReg <- mkReg(META_DATA_ALLOC_PD);

    ADDR defaultAddr   = fromInteger(0);
    Length defaultLen  = fromInteger(valueOf(RDMA_MAX_LEN));
    let defaultAccPerm = enum2Flag(IBV_ACCESS_REMOTE_WRITE);

    // Vector#(MAX_QP, Reg#(Bool)) qpModifyDoneRegVec <- replicateM(mkReg(False));

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

        $display("time=%0t: pdKey=%h", $time, pdKey);
    endrule

    rule respAllocPDs if (initMetaDataStateReg == META_DATA_ALLOC_PD);
        if (isZero(pdRespCnt)) begin
            initMetaDataStateReg <= META_DATA_ALLOC_MR;
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
            pdHandlerQ4ReqMR.enq(allocRespPD.pdHandler);
            pdHandlerQ4RespMR.enq(allocRespPD.pdHandler);
            pdHandlerQ4ReqQP.enq(allocRespPD.pdHandler);
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

        $display("time=%0t: pdRespCnt=%0d", $time, pdRespCnt);
    endrule

    rule allocMRs if (
        !isZero(mrReqCnt) && initMetaDataStateReg == META_DATA_ALLOC_MR
    );
        mrReqCnt.decr(1);

        if (isZero(mrReqPerPdCnt)) begin
            mrReqPerPdCnt <= fromInteger(mrPerPD - 1);
            pdHandlerQ4ReqMR.deq;
        end
        else begin
            mrReqPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4ReqMR.first;

        let mrKey = mrKeyPipeOut.first;
        mrKeyPipeOut.deq;

        let allocReqMR = ReqMR {
            allocOrNot: True,
            mr: MemRegion {
                laddr    : defaultAddr,
                len      : defaultLen,
                accFlags : defaultAccPerm,
                pdHandler: pdHandler,
                lkeyPart : mrKey,
                rkeyPart : mrKey
            },
            lkeyOrNot: False,
            rkey     : dontCareValue,
            lkey     : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4MR allocReqMR);

        $display("time=%0t: mrKey=%h", $time, mrKey);
    endrule

    rule respAllocMRs if (initMetaDataStateReg == META_DATA_ALLOC_MR);
        if (isZero(mrRespCnt)) begin
            initMetaDataStateReg <= META_DATA_CREATE_QP;
            // $display("time=%0t: next to create QPs, qpReqCnt=%0d", $time, qpReqCnt);
        end
        else begin
            mrRespCnt.decr(1);
        end

        if (isZero(mrRespPerPdCnt)) begin
            mrRespPerPdCnt <= fromInteger(mrPerPD - 1);
            pdHandlerQ4RespMR.deq;
        end
        else begin
            mrRespPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4RespMR.first;

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
            lKeyQ4Fill.enq(tuple2(pdHandler, allocRespMR.lkey));
            rKeyQ4Fill.enq(tuple2(pdHandler, allocRespMR.rkey));
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

        $display("time=%0t: mrRespCnt=%0d", $time, mrRespCnt);
    endrule

    rule reqCreateQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CREATE_QP
    );
        qpReqCnt.decr(1);

        if (isZero(qpPerPdCnt)) begin
            qpPerPdCnt <= fromInteger(qpPerPD - 1);
            pdHandlerQ4ReqQP.deq;
        end
        else begin
            qpPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4ReqQP.first;

        let createReqQP = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : pdHandler,
            qpn       : dontCareValue,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
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
            qpnQ4Init.enq(qpn);
            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     qpn, qpRespCnt
            // );
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
            qpnQ4RTR.enq(qpn);
            // $display(
            //     "time=%0t: initRespQP=", $time, fshow(initRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     $time, qpn, qpRespCnt
            // );
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
    endrule

    rule reqRtrQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_RTR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4RTR.first;
        qpnQ4RTR.deq;

        let qpAttr = qpAttrPipeOut.first;
        // qpAttrPipeOut.deq;

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
    endrule

    rule respRtrQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            if (isSendSideQ) begin
                initMetaDataStateReg <= META_DATA_SET_QP_RTS;
            end
            else begin
                initMetaDataStateReg <= META_DATA_DESTROY_QP;
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

            let qpn = setRtrRespQP.qpn;
            qpnQ4RTS.enq(qpn);
            // $display(
            //     "time=%0t: setRtrRespQP=", $time, fshow(setRtrRespQP),
            //     " should be success, and setRtrRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtrRespQP.qpn, qpRespCnt
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
        // $display("time=%0t: reqRtsQPs, qpReqCnt=%0d", $time, qpReqCnt);
    endrule

    rule respRtsQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTS);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            initMetaDataStateReg <= META_DATA_DESTROY_QP;
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

            let qpn = setRtsRespQP.qpn;
            qpnQ4Destroy.enq(qpn);
            // $display(
            //     "time=%0t: setRtsRespQP=", $time, fshow(setRtsRespQP),
            //     " should be success, and setRtsRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtsRespQP.qpn, qpRespCnt
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
        $display("time=%0t: reqDestroyQPs, qpReqCnt=%0d", $time, qpReqCnt);
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

            // let qpn = destroyRespQP.qpn;
            // qpnQ4Destroy.enq(qpn);
            $display(
                "time=%0t: destroyRespQP=", $time, fshow(destroyRespQP),
                " should be success, and destroyRespQP.qpn=%h, qpRespCnt=%h",
                $time, destroyRespQP.qpn, qpRespCnt
            );
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

    rule done if (initMetaDataStateReg == META_DATA_NO_OP);
        if (isSendSideQ) begin
            normalExit;
        end
        else begin
            $display();
        end
    endrule
endmodule
*/
