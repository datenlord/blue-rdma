import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

typedef enum {
    TEST_META_DATA_FILL,
    TEST_META_DATA_ACT,
    TEST_META_DATA_POP
} SeqTestState deriving(Bits, Eq);

(* doc = "testcase" *)
module mkTestMetaDataPDs(Empty);
    let pdMetaDataDUT <- mkMetaDataPDs;
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD)))) pdReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_PD)))          pdRespCnt <- mkCount(0);

    PipeOut#(KeyPD) pdKeyPipeOut <- mkGenericRandomPipeOut;
    Vector#(2, PipeOut#(KeyPD)) pdKeyPipeOutVec <-
        mkForkVector(pdKeyPipeOut);
    let pdKeyPipeOut4InsertReq = pdKeyPipeOutVec[0];
    let pdKeyPipeOut4InsertResp <- mkBufferN(2, pdKeyPipeOutVec[1]);
    FIFOF#(HandlerPD) pdHandlerQ4Search <- mkSizedFIFOF(valueOf(MAX_PD));
    FIFOF#(HandlerPD) pdHandlerQ4Pop <- mkSizedFIFOF(valueOf(MAX_PD));

    Reg#(SeqTestState) pdTestStateReg <- mkReg(TEST_META_DATA_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule allocPDs if (pdTestStateReg == TEST_META_DATA_FILL);
        if (pdReqCnt < fromInteger(valueOf(MAX_PD))) begin
            let pdKey = pdKeyPipeOut4InsertReq.first;
            pdKeyPipeOut4InsertReq.deq;

            let allocReq = ReqPD {
                allocOrNot: True,
                pdKey     : pdKey,
                pdHandler : dontCareValue
                // cbIndex   : dontCareValue
            };
            pdMetaDataDUT.srvPort.request.put(allocReq);
            pdReqCnt.incr(1);
        end
    endrule

    rule allocResp if (pdTestStateReg == TEST_META_DATA_FILL);
        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_META_DATA_ACT;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let allocResp <- pdMetaDataDUT.srvPort.response.get;
        immAssert(
            allocResp.successOrNot,
            "allocResp.successOrNot assertion @ mkTestMetaDataPDs",
            $format(
                "allocResp.successOrNot=", fshow(allocResp.successOrNot),
                " should be valid when pdCnt=%0d", pdRespCnt
            )
        );

        let pdHandler = allocResp.pdHandler;
        let pdKey = allocResp.pdKey;
        pdHandlerQ4Search.enq(pdHandler);
        pdHandlerQ4Pop.enq(pdHandler);

        let pdKeyRef = pdKeyPipeOut4InsertResp.first;
        pdKeyPipeOut4InsertResp.deq;

        immAssert(
            pdKey == truncate(pdHandler) && pdKey == pdKeyRef,
            "pdKey assertion @ mkTestMetaDataPDs",
            $format(
                "pdKey=%h should match pdHandler=%h and pdKeyRef=%h",
                pdKey, pdHandler, pdKeyRef
            )
        );
        // $display(
        //     "time=%0t: pdKey=%h, pdHandler=%h, pdRespCnt=%0d when allocate MetaDataPDs, pdMetaDataDUT.notFull=",
        //     $time, pdKey, pdHandler, pdRespCnt, fshow(pdMetaDataDUT.notFull)
        // );
    endrule

    rule compareSearch if (pdTestStateReg == TEST_META_DATA_ACT);
        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_META_DATA_POP;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let pdHandler2Search = pdHandlerQ4Search.first;
        pdHandlerQ4Search.deq;

        let isValidPD = pdMetaDataDUT.isValidPD(pdHandler2Search);
        immAssert(
            isValidPD,
            "isValidPD assertion @ mkTestMetaDataPDs",
            $format(
                "isValidPD=", fshow(isValidPD),
                " should be valid when pdHandler2Search=%h and pdRespCnt=%0d",
                pdHandler2Search, pdRespCnt
            )
        );

        let maybeMRs = pdMetaDataDUT.getMRs4PD(pdHandler2Search);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestMetaDataPDs",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid when pdHandler2Search=%h and pdRespCnt=%0d",
                pdHandler2Search, pdRespCnt
            )
        );
        // $display(
        //     "time=%0t: isValid(maybeMRs)=", $time, fshow(isValid(maybeMRs)),
        //     " should be valid when pdHandler2Search=%0d and pdRespCnt=%0d",
        //     pdHandler2Search, pdRespCnt
        // );
    endrule

    rule deAllocPDs if (pdTestStateReg == TEST_META_DATA_POP);
        if (pdReqCnt < fromInteger(valueOf(MAX_PD))) begin
            let pdHandler2Remove = pdHandlerQ4Pop.first;
            pdHandlerQ4Pop.deq;

            let deAllocReq = ReqPD {
                allocOrNot: False,
                pdKey     : dontCareValue,
                pdHandler : pdHandler2Remove
                // cbIndex   : dontCareValue
            };
            pdMetaDataDUT.srvPort.request.put(deAllocReq);
            pdReqCnt.incr(1);
        end
    endrule

    rule deAllocResp if (pdTestStateReg == TEST_META_DATA_POP);
        countDown.decr;

        if (pdRespCnt == fromInteger(valueOf(MAX_PD) - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            pdTestStateReg <= TEST_META_DATA_FILL;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let deAllocResp <- pdMetaDataDUT.srvPort.response.get;
        let pdHandler = deAllocResp.pdHandler;
        let pdKey = deAllocResp.pdKey;
        immAssert(
            deAllocResp.successOrNot,
            "deAllocResp.successOrNot assertion @ mkTestMetaDataPDs",
            $format(
                "deAllocResp.successOrNot=", fshow(deAllocResp.successOrNot),
                " should be true when pdRespCnt=%0d", pdRespCnt
            )
        );
        immAssert(
            pdKey == truncate(pdHandler),
            "pdKey assertion @ mkTestMetaDataPDs",
            $format(
                "pdKey=%h should match pdHandler=%h",
                pdKey, pdHandler
            )
        );
        // $display(
        //     "time=%0t: deAllocResp=", $time, fshow(deAllocResp),
        //     " should be true when pdRespCnt=%0d", pdRespCnt
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestMetaDataMRs(Empty);
    let mrMetaDataDUT <- mkMetaDataMRs;

    Count#(Bit#(TLog#(TAdd#(1, MAX_MR_PER_PD)))) mrReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD))) mrRespCnt <- mkCount(0);

    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;
    Vector#(2, PipeOut#(KeyPartMR)) mrKeyPipeOutVec <-
        mkForkVector(mrKeyPipeOut);
    let mrKeyPipeOut4InsertReq = mrKeyPipeOutVec[0];
    let mrKeyPipeOut4InsertResp <- mkBufferN(2, mrKeyPipeOutVec[1]);
    FIFOF#(LKEY) lkeyQ4Search <- mkSizedFIFOF(valueOf(MAX_MR_PER_PD));
    FIFOF#(RKEY) rkeyQ4Pop <- mkSizedFIFOF(valueOf(MAX_MR_PER_PD));
    FIFOF#(RKEY) rkeyQ4Comp <- mkFIFOF;

    Reg#(SeqTestState) mrTestStateReg <- mkReg(TEST_META_DATA_FILL);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule allocMRs if (mrTestStateReg == TEST_META_DATA_FILL);
        if (mrReqCnt < fromInteger(valueOf(MAX_MR_PER_PD))) begin
            let curMrKey = mrKeyPipeOut4InsertReq.first;
            mrKeyPipeOut4InsertReq.deq;

            let allocReq = ReqMR {
                allocOrNot   : True,
                mr           : MemRegion {
                    laddr    : dontCareValue,
                    len      : dontCareValue,
                    accFlags : dontCareValue,
                    pdHandler: dontCareValue,
                    lkeyPart : curMrKey,
                    rkeyPart : curMrKey
                },
                lkeyOrNot    : False,
                lkey         : dontCareValue,
                rkey         : dontCareValue
                // cbIndex      : dontCareValue
            };

            mrMetaDataDUT.srvPort.request.put(allocReq);
            mrReqCnt.incr(1);
        end
    endrule

    rule allocResp if (mrTestStateReg == TEST_META_DATA_FILL);
        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_META_DATA_ACT;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let allocResp <- mrMetaDataDUT.srvPort.response.get;
        immAssert(
            allocResp.successOrNot,
            "allocResp.successOrNot assertion @ mkTestMetaDataMRs",
            $format(
                "allocResp.successOrNot=", fshow(allocResp.successOrNot),
                " should be valid"
            )
        );
        let lkey = allocResp.lkey;
        let rkey = allocResp.rkey;
        lkeyQ4Search.enq(lkey);
        rkeyQ4Pop.enq(rkey);

        let mrKeyPart = mrKeyPipeOut4InsertResp.first;
        mrKeyPipeOut4InsertResp.deq;

        immAssert(
            mrKeyPart == truncate(lkey),
            "lkey assertion @ mkTestMetaDataMRs",
            $format(
                "lkey=%h should match mrKeyPart=%h",
                lkey, mrKeyPart
            )
        );
        immAssert(
            mrKeyPart == truncate(rkey),
            "rkey assertion @ mkTestMetaDataMRs",
            $format(
                "rkey=%h should match mrKeyPart=%h",
                rkey, mrKeyPart
            )
        );

        IndexMR mrIndex = unpack(truncateLSB(lkey));
        // $display(
        //     "time=%0t: mrIndex=%h, lkey=%h, rkey=%h, mrRespCnt=%0d when allocate MetaDataMRs, mrMetaDataDUT.notFull=",
        //     $time, mrIndex, lkey, rkey, mrRespCnt, fshow(mrMetaDataDUT.notFull)
        // );
    endrule

    rule compareSearch if (mrTestStateReg == TEST_META_DATA_ACT);
        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_META_DATA_POP;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let lkey2Search = lkeyQ4Search.first;
        lkeyQ4Search.deq;

        let maybeMR = mrMetaDataDUT.getMemRegionByLKey(lkey2Search);
        immAssert(
            isValid(maybeMR),
            "maybeMR assertion @ mkTestMetaDataMRs",
            $format(
                "maybeMR=", fshow(maybeMR),
                " should be valid when lkey2Search=%h and mrReqCnt=%0d",
                lkey2Search, mrReqCnt
            )
        );
        // $display(
        //     "time=%0t: maybeMR=", $time, fshow(maybeMR),
        //     " should be valid when lkey2Search=%h and mrReqCnt=%0d",
        //     lkey2Search, mrReqCnt
        // );
    endrule

    rule deAllocMRs if (mrTestStateReg == TEST_META_DATA_POP);
        if (mrReqCnt < fromInteger(valueOf(MAX_MR_PER_PD))) begin
            let rkey2Remove = rkeyQ4Pop.first;
            rkeyQ4Pop.deq;

            let deAllocReq = ReqMR {
                allocOrNot   : False,
                mr           : dontCareValue,
                lkeyOrNot    : False,
                lkey         : dontCareValue,
                rkey         : rkey2Remove
                // cbIndex      : dontCareValue
            };

            mrMetaDataDUT.srvPort.request.put(deAllocReq);
            rkeyQ4Comp.enq(rkey2Remove);
            mrReqCnt.incr(1);

            // $display(
            //     "time=%0t: deAllocReq=", $time, fshow(deAllocReq),
            //     " should be true when rkey2Remove=%h and mrReqCnt=%0d",
            //     rkey2Remove, mrReqCnt
            // );
        end
    endrule

    rule deAllocResp if (mrTestStateReg == TEST_META_DATA_POP);
        countDown.decr;

        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt  <= 0;
            mrRespCnt <= 0;
            mrTestStateReg <= TEST_META_DATA_FILL;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let rkey2Remove = rkeyQ4Comp.first;
        rkeyQ4Comp.deq;

        let deAllocResp <- mrMetaDataDUT.srvPort.response.get;
        immAssert(
            deAllocResp.successOrNot,
            "deAllocResp.successOrNot assertion @ mkTestMetaDataMRs",
            $format(
                "deAllocResp.successOrNot=", fshow(deAllocResp.successOrNot),
                " should be true when mrRespCnt=%0d", mrRespCnt
            )
        );
        immAssert(
            rkey2Remove == deAllocResp.rkey,
            "rkey assertion @ mkTestMetaDataMRs",
            $format(
                "rkey2Remove=%h should == deAllocResp.rkey=%h",
                rkey2Remove, deAllocResp.rkey
            )
        );

        // $display(
        //     "time=%0t: deAllocResp=", $time, fshow(deAllocResp),
        //     " should be true when rkey2Remove=%h and mrRespCnt=%0d",
        //     rkey2Remove, mrRespCnt
        // );
    endrule
endmodule

typedef enum {
    TEST_META_DATA_PD_ALLOC,
    TEST_META_DATA_PD_DEALLOC,
    TEST_META_DATA_QP_CREATE,
    TEST_META_DATA_QP_INIT,
    TEST_META_DATA_QP_RTR,
    TEST_META_DATA_QP_ERR,
    TEST_META_DATA_QP_CHECK,
    TEST_META_DATA_QP_DESTROY
} TestMetaDataSrvState deriving(Bits, Eq);

(* doc = "testcase" *)
module mkTestMetaDataQPs(Empty) provisos(
    NumAlias#(TLog#(MAX_QP), qpNumWidth),
    Add#(TLog#(MAX_QP), 1, TLog#(TAdd#(1, MAX_QP))) // MAX_QP must be power of 2
);
    let qpType = IBV_QPT_XRC_SEND; // IBV_QPT_RC; //
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

    let qpMetaDataDUT <- mkMetaDataQPs;
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) qpReqCnt <- mkCount(fromInteger(valueOf(MAX_QP)));
    Count#(Bit#(TLog#(MAX_QP)))          qpRespCnt <- mkCount(fromInteger(valueOf(MAX_QP) - 1));

    PipeOut#(HandlerPD) pdHandlerPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(HandlerPD)) pdHandlerPipeOutVec <-
        mkForkVector(pdHandlerPipeOut);
    let pdHandlerPipeOut4InsertReq = pdHandlerPipeOutVec[0];
    let pdHandlerPipeOut4InsertResp <- mkBufferN(2, pdHandlerPipeOutVec[1]);
    let pdHandlerPipeOut4Search <- mkBufferN(valueOf(MAX_QP), pdHandlerPipeOutVec[2]);
    FIFOF#(QPN) qpnQ4Init    <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(QPN) qpnQ4RTR     <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(QPN) qpnQ4ERR     <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(QPN) qpnQ4Search  <- mkSizedFIFOF(valueOf(MAX_QP));
    FIFOF#(QPN) qpnQ4Destroy <- mkSizedFIFOF(valueOf(MAX_QP));

    Reg#(TestMetaDataSrvState) qpTestStateReg <- mkReg(TEST_META_DATA_QP_CREATE);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function Tuple2#(
        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH)),
        Bit#(TSub#(QPN_WIDTH, QP_INDEX_WIDTH))
    ) extractCommonPartFromPdHandlerAndQPN(HandlerPD pdHandler, QPN qpn);
        return tuple2(truncate(pdHandler), truncate(qpn));
    endfunction

    rule reqCreateQPs if (!isZero(qpReqCnt) && qpTestStateReg == TEST_META_DATA_QP_CREATE);
        qpReqCnt.decr(1);

        let curPdHandler = pdHandlerPipeOut4InsertReq.first;
        pdHandlerPipeOut4InsertReq.deq;

        let createReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : curPdHandler,
            qpn       : dontCareValue,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };
        qpMetaDataDUT.srvPort.request.put(createReq);
    endrule

    rule respCreateQPs if (qpTestStateReg == TEST_META_DATA_QP_CREATE);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_INIT;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let createResp <- qpMetaDataDUT.srvPort.response.get;
        immAssert(
            createResp.successOrNot,
            "createResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "createResp.successOrNot=", fshow(createResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );

        let qpn = createResp.qpn;
        let pdHandler = createResp.pdHandler;
        qpnQ4Init.enq(qpn);
        qpnQ4RTR.enq(qpn);
        qpnQ4ERR.enq(qpn);
        qpnQ4Search.enq(qpn);
        qpnQ4Destroy.enq(qpn);

        let refHandlerPD = pdHandlerPipeOut4InsertResp.first;
        pdHandlerPipeOut4InsertResp.deq;

        let { pdPart, qpnPart } = extractCommonPartFromPdHandlerAndQPN(refHandlerPD, qpn);
        immAssert(
            qpnPart == pdPart && pdHandler == refHandlerPD,
            "qpnPart assertion @ mkTestMetaDataQPs",
            $format(
                "qpnPart=%h should == pdPart=%h",
                qpnPart, pdPart,
                " and pdHandler=%h should == refHandlerPD=%h",
                pdHandler, refHandlerPD
            )
        );

        // $display(
        //     "time=%0t: qpn=%h should match refHandlerPD=%h and pdHandler=%h",
        //     $time, qpn, refHandlerPD, pdHandler
        // );
    endrule

    rule reqInitQPs if (!isZero(qpReqCnt) && qpTestStateReg == TEST_META_DATA_QP_INIT);
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
            qpInitAttr: qpInitAttr
        };
        qpMetaDataDUT.srvPort.request.put(initReqQP);
    endrule

    rule respInitQPs if (qpTestStateReg == TEST_META_DATA_QP_INIT);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_RTR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let initResp <- qpMetaDataDUT.srvPort.response.get;
        immAssert(
            initResp.successOrNot,
            "initResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "initResp.successOrNot=", fshow(initResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );
    endrule

    rule reqRtrQPs if (!isZero(qpReqCnt) && qpTestStateReg == TEST_META_DATA_QP_RTR);
        qpReqCnt.decr(1);

        let qpn = qpnQ4RTR.first;
        qpnQ4RTR.deq;

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.dqpn = qpn;
        qpAttr.qpState = IBV_QPS_RTR;
        let setRtrReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        qpMetaDataDUT.srvPort.request.put(setRtrReqQP);
    endrule

    rule respRtrQPs if (qpTestStateReg == TEST_META_DATA_QP_RTR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_ERR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let rtrResp <- qpMetaDataDUT.srvPort.response.get;
        immAssert(
            rtrResp.successOrNot,
            "rtrResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "rtrResp.successOrNot=", fshow(rtrResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );
    endrule

    rule reqErrQPs if (!isZero(qpReqCnt) && qpTestStateReg == TEST_META_DATA_QP_ERR);
        qpReqCnt.decr(1);

        let qpn = qpnQ4ERR.first;
        qpnQ4ERR.deq;

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_ERR;
        let reqErrQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getOnlyStateRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        qpMetaDataDUT.srvPort.request.put(reqErrQP);
    endrule

    rule respErrQPs if (qpTestStateReg == TEST_META_DATA_QP_ERR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_CHECK;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let errResp <- qpMetaDataDUT.srvPort.response.get;
        immAssert(
            errResp.successOrNot,
            "errResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "errResp.successOrNot=", fshow(errResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );
    endrule

    rule compareSearch if (qpTestStateReg == TEST_META_DATA_QP_CHECK);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_DESTROY;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let qpn2Search = qpnQ4Search.first;
        qpnQ4Search.deq;

        let isValidQP = qpMetaDataDUT.isValidQP(qpn2Search);
        immAssert(
            isValidQP,
            "isValidQP assertion @ mkTestMetaDataQPs",
            $format(
                "isValidQP=", fshow(isValidQP),
                " should be valid when qpn2Search=%h and qpRespCnt=%0d",
                qpn2Search, qpRespCnt
            )
        );

        let maybePD = qpMetaDataDUT.getPD(qpn2Search);
        immAssert(
            isValid(maybePD),
            "maybePD assertion @ mkTestMetaDataQPs",
            $format(
                "maybePD=", fshow(isValid(maybePD)),
                " should be valid"
            )
        );

        let pdHandler = unwrapMaybe(maybePD);
        let refPdHandler = pdHandlerPipeOut4Search.first;
        pdHandlerPipeOut4Search.deq;

        immAssert(
            pdHandler == refPdHandler,
            "pdHandler assertion @ mkTestMetaDataQPs",
            $format(
                "pdHandler=%h should match refPdHandler=%h",
                pdHandler, refPdHandler
            )
        );

        let qp = qpMetaDataDUT.getQueuePairByQPN(qpn2Search);
        immAssert(
            qp.statusSQ.comm.isERR,
            "QP CntrlStatus assertion @ mkTestMetaDataQPs",
            $format(
                "qp.statusSQ.comm.isERR=", fshow(qp.statusSQ.comm.isERR),
                " should be true"
            )
        );

        // $display(
        //     "time=%0t: isValidQP=", $time, fshow(isValidQP),
        //     " should be valid when qpn2Search=%h and qpCnt=%0d",
        //     qpn2Search, qpCnt
        // );
    endrule

    rule reqDestroyQPs if (!isZero(qpReqCnt) && qpTestStateReg == TEST_META_DATA_QP_DESTROY);
        qpReqCnt.decr(1);

        let qpn2Destroy = qpnQ4Destroy.first;
        qpnQ4Destroy.deq;

        let destroyReq = ReqQP {
            qpReqType : REQ_QP_DESTROY,
            pdHandler : dontCareValue,
            qpn       : qpn2Destroy,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: dontCareValue
        };
        qpMetaDataDUT.srvPort.request.put(destroyReq);
    endrule

    rule respDestroyQPs if (qpTestStateReg == TEST_META_DATA_QP_DESTROY);
        countDown.decr;

        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(valueOf(MAX_QP));
            qpRespCnt <= fromInteger(valueOf(MAX_QP) - 1);
            qpTestStateReg <= TEST_META_DATA_QP_CREATE;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let destroyResp <- qpMetaDataDUT.srvPort.response.get;
        let pdHandler = destroyResp.pdHandler;
        let qpn = destroyResp.qpn;
        immAssert(
            destroyResp.successOrNot,
            "destroyResp.successOrNot assertion @ mkTestMetaDataQPs",
            $format(
                "destroyResp.successOrNot=", fshow(destroyResp.successOrNot),
                " should be true when qpRespCnt=%0d", qpRespCnt
            )
        );

        let { pdPart, qpnPart } = extractCommonPartFromPdHandlerAndQPN(pdHandler, qpn);
        immAssert(
            qpnPart == pdPart,
            "qpnPart assertion @ mkTestMetaDataQPs",
            $format(
                "qpnPart=%h should == pdPart=%h",
                qpnPart, pdPart,
                ", when qpn=%h, pdHandler=%h",
                qpn, pdHandler
            )
        );

        // $display(
        //     "time=%0t: destroyResp=", $time, fshow(destroyResp),
        //     " should be true when qpRespCnt=%0d", qpRespCnt
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestPermCheckSrv(Empty);
    let pdMetaData  <- mkMetaDataPDs;
    let permCheckSrv <- mkPermCheckSrv(pdMetaData);

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))  pdReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD)))) pdRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))     mrReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(MAX_MR_PER_PD)))    mrRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, TMul#(MAX_PD, MAX_MR_PER_PD))))) mrTotalReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(MAX_PD, MAX_MR_PER_PD))))          mrTotalRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(MAX_PD, MAX_MR_PER_PD))))            searchReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TMul#(2, TMul#(MAX_PD, MAX_MR_PER_PD))))) searchRespCnt <- mkCount(0);

    let pdNum = valueOf(MAX_PD);
    let mrNumPerPD = valueOf(MAX_MR_PER_PD);
    let mrTotalNum = valueOf(TMul#(MAX_PD, MAX_MR_PER_PD));
    let totalSearchNum = valueOf(TMul#(2, TMul#(MAX_PD, MAX_MR_PER_PD)));

    PipeOut#(KeyPD)     pdKeyPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(KeyPartMR) mrKeyPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(HandlerPD)  pdHandlerQ4FillMR <- mkFIFOF;
    FIFOF#(HandlerPD) pdHandlerQ4CheckMR <- mkFIFOF;
    FIFOF#(Tuple2#(HandlerPD, LKEY)) lKeyQ4Search <- mkSizedFIFOF(valueOf(TMul#(MAX_PD, MAX_MR_PER_PD)));
    FIFOF#(Tuple2#(HandlerPD, RKEY)) rKeyQ4Search <- mkSizedFIFOF(valueOf(TMul#(MAX_PD, MAX_MR_PER_PD)));

    Reg#(SeqTestState) mrCheckStateReg <- mkReg(TEST_META_DATA_FILL);
    Reg#(Bool) rkeySearchReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    ADDR defaultAddr   = fromInteger(0);
    Length defaultLen  = fromInteger(valueOf(RDMA_MAX_LEN));
    let defaultAccPerm = enum2Flag(IBV_ACCESS_REMOTE_WRITE);

    rule allocPDs if (pdReqCnt < fromInteger(pdNum) && mrCheckStateReg == TEST_META_DATA_FILL);
        pdReqCnt.incr(1);
        let pdKey = pdKeyPipeOut.first;
        pdKeyPipeOut.deq;

        let allocReqPD = ReqPD {
            allocOrNot: True,
            pdKey     : pdKey,
            pdHandler : dontCareValue
            // cbIndex   : dontCareValue
        };
        pdMetaData.srvPort.request.put(allocReqPD);

        // $display("time=%0t: pdKey=%h", $time, pdKey);
    endrule

    rule allocRespPDs if (pdRespCnt < fromInteger(pdNum) && mrCheckStateReg == TEST_META_DATA_FILL);
        pdRespCnt.incr(1);
        let allocRespPD <- pdMetaData.srvPort.response.get;
        immAssert(
            allocRespPD.successOrNot,
            "allocRespPD.successOrNot assertion @ mkTestPermCheckSrv",
            $format(
                "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                " should be true when pdRespCnt=%0d", pdRespCnt
            )
        );

        pdHandlerQ4FillMR.enq(allocRespPD.pdHandler);
        pdHandlerQ4CheckMR.enq(allocRespPD.pdHandler);
        // $display("time=%0t: pdHandler=%h", $time, pdHandler);
    endrule

    rule allocMRs if (mrTotalReqCnt < fromInteger(mrTotalNum) && mrCheckStateReg == TEST_META_DATA_FILL);
        let pdHandler = pdHandlerQ4FillMR.first;

        if (mrReqCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrReqCnt <= 0;
            pdHandlerQ4FillMR.deq;
        end
        else begin
            mrReqCnt.incr(1);
        end
        mrTotalReqCnt.incr(1);

        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestPermCheckSrv",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid for pdHandler=%h", pdHandler
            )
        );

        // let mrMetaData = unwrapMaybe(maybeMRs);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
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
                // cbIndex  : dontCareValue
            };
            mrMetaData.srvPort.request.put(allocReqMR);

            // $display("time=%0t: mrKey=%h", $time, mrKey);
        end
    endrule

    rule allocRespMRs if (mrCheckStateReg == TEST_META_DATA_FILL);
        if (mrTotalRespCnt == fromInteger(mrTotalNum - 1)) begin
            mrTotalRespCnt <= 0;
            mrCheckStateReg <= TEST_META_DATA_ACT;
        end
        else begin
            mrTotalRespCnt.incr(1);
        end

        if (mrRespCnt == fromInteger(valueOf(MAX_MR_PER_PD) - 1)) begin
            mrRespCnt <= 0;
            pdHandlerQ4CheckMR.deq;
        end
        else begin
            mrRespCnt.incr(1);
        end

        let pdHandler = pdHandlerQ4CheckMR.first;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        immAssert(
            isValid(maybeMRs),
            "maybeMRs assertion @ mkTestPermCheckSrv",
            $format(
                "isValid(maybeMRs)=", fshow(isValid(maybeMRs)),
                " should be valid for pdHandler=%h", pdHandler
            )
        );

        // let mrMetaData = unwrapMaybe(maybeMRs);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            let allocRespMR <- mrMetaData.srvPort.response.get;
            immAssert(
                allocRespMR.successOrNot,
                "allocRespMR.successOrNot assertion @ mkTestMetaDataMRs",
                $format(
                    "allocRespMR.successOrNot=", fshow(allocRespMR.successOrNot),
                    " should be valid"
                )
            );

            let lkey = allocRespMR.lkey;
            let rkey = allocRespMR.rkey;
            // immAssert(
            //     isValid(rkey),
            //     "rkey assertion @ mkTestPermCheckSrv",
            //     $format("rkey=", rkey, " should be valid")
            // );

            lKeyQ4Search.enq(tuple2(pdHandler, lkey));
            rKeyQ4Search.enq(tuple2(pdHandler, rkey));

            // $display("time=%0t: lkey=%h, rkey=%h", $time, lkey, rkey);
        end
        // $display(
        //     "time=%0t: mrTotalRespCnt=%0d, mrRespCnt=%0d",
        //     $time, mrTotalRespCnt, mrRespCnt
        // );
    endrule

    rule checkReqByLKey if (!rkeySearchReg && mrCheckStateReg == TEST_META_DATA_ACT);
        if (searchReqCnt == fromInteger(mrTotalNum - 1)) begin
            rkeySearchReg <= True;
            searchReqCnt <= 0;
        end
        else begin
            searchReqCnt.incr(1);
        end

        let { pdHandler, lkey } = lKeyQ4Search.first;
        lKeyQ4Search.deq;

        let permCheckReq = PermCheckReq {
            wrID         : tagged Invalid,
            lkey         : lkey,
            rkey         : dontCareValue,
            localOrRmtKey: True,
            reqAddr      : defaultAddr,
            totalLen     : defaultLen,
            pdHandler    : pdHandler,
            isZeroDmaLen : isZero(defaultLen),
            accFlags     : defaultAccPerm
        };

        permCheckSrv.request.put(permCheckReq);
        // $display(
        //     "time=%0t: checkReqByLKey permCheckReq=", $time, fshow(permCheckReq)
        // );
    endrule

    rule checkReqByRKey if (rkeySearchReg && mrCheckStateReg == TEST_META_DATA_ACT);
        if (searchReqCnt == fromInteger(mrTotalNum - 1)) begin
            rkeySearchReg <= False;
            searchReqCnt <= 0;
        end
        else begin
            searchReqCnt.incr(1);
        end

        let { pdHandler, rkey } = rKeyQ4Search.first;
        rKeyQ4Search.deq;

        let permCheckReq = PermCheckReq {
            wrID         : tagged Invalid,
            lkey         : dontCareValue,
            rkey         : rkey,
            localOrRmtKey: False,
            reqAddr      : defaultAddr,
            totalLen     : defaultLen,
            pdHandler    : pdHandler,
            isZeroDmaLen : isZero(defaultLen),
            accFlags     : defaultAccPerm
        };

        permCheckSrv.request.put(permCheckReq);
        // $display(
        //     "time=%0t: checkReqByRKey permCheckReq=", $time, fshow(permCheckReq)
        // );
    endrule

    rule checkResp if (mrCheckStateReg == TEST_META_DATA_ACT);
        if (searchRespCnt == fromInteger(totalSearchNum - 1)) begin
            searchRespCnt <= 0;
            mrCheckStateReg <= TEST_META_DATA_POP;
        end
        else begin
            searchRespCnt.incr(1);
        end

        let checkResp <- permCheckSrv.response.get;
        immAssert(
            checkResp,
            "checkResp @ mkTestPermCheckSrv",
            $format(
                "checkResp=", fshow(checkResp), " should be true"
            )
        );

        // if (lKeyPermCheckReqQ.notEmpty) begin
        //     let lKeyCheckResp <- permCheckSrv.response.get;
        //     immAssert(
        //         lKeyCheckResp,
        //         "lKeyCheckResp @ mkTestPermCheckSrv",
        //         $format(
        //             "lKeyCheckResp=", fshow(lKeyCheckResp),
        //             " should be true"
        //         )
        //     );
        //     searchCnt.decr(1);

        //     $display(
        //         "time=%0t: lKeyCheckResp=", $time, fshow(lKeyCheckResp), " should be true"
        //     );
        // end
        // else if (rKeyPermCheckReqQ.notEmpty) begin
        //     let rKeyCheckResp <- permCheckSrv.response.get;
        //     immAssert(
        //         rKeyCheckResp,
        //         "rKeyCheckResp @ mkTestPermCheckSrv",
        //         $format(
        //             "rKeyCheckResp=", fshow(rKeyCheckResp),
        //             " should be true"
        //         )
        //     );
        //     searchCnt.decr(1);

        //     $display(
        //         "time=%0t: rKeyCheckResp=", $time, fshow(rKeyCheckResp), " should be true"
        //     );
        // end

        countDown.decr;
        // $display(
        //     "time=%0t: searchRespCnt=%0d, checkResp=",
        //     $time, searchRespCnt, fshow(checkResp),
        //     " should be true"
        // );
    endrule

    rule clear if (mrCheckStateReg == TEST_META_DATA_POP);
        pdReqCnt  <= 0;
        pdRespCnt <= 0;
        mrReqCnt  <= 0;
        mrRespCnt <= 0;
        mrTotalReqCnt  <= 0;
        mrTotalRespCnt <= 0;
        searchReqCnt   <= 0;
        searchRespCnt  <= 0;

        pdHandlerQ4FillMR.clear;
        pdHandlerQ4CheckMR.clear;
        lKeyQ4Search.clear;
        rKeyQ4Search.clear;

        pdMetaData.clear;

        mrCheckStateReg <= TEST_META_DATA_FILL;

        // $display("time=%0t: clear", $time);
    endrule
endmodule

(* doc = "testcase" *)
module mkTestMetaDataSrv(Empty) provisos(
    NumAlias#(TDiv#(MAX_QP, MAX_PD), qpPerPD),
    Add#(TMul#(MAX_PD, qpPerPD), 0, MAX_QP) // MAX_QP can be divided by MAX_PD
);
    let qpType = IBV_QPT_XRC_SEND; // IBV_QPT_RC; //
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

    let pdMetaData  <- mkMetaDataPDs;
    let qpMetaData  <- mkMetaDataQPs;
    let metaDataSrv <- mkMetaDataSrv(pdMetaData, qpMetaData);

    let pdNum = valueOf(MAX_PD);
    let qpNum = valueOf(MAX_QP);
    // let qpPerPD = valueOf(TDiv#(MAX_QP, MAX_PD));

    PipeOut#(KeyPD) pdKeyPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(HandlerPD) pdHandlerQ4Fill <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD) pdHandlerQ4Pop  <- mkSizedFIFOF(pdNum);

    FIFOF#(QPN)    qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4RTR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)     qpnQ4ERR <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN) qpnQ4Destroy <- mkSizedFIFOF(qpNum);

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))  pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))           pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))  qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))           qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    Count#(Bit#(TLog#(qpPerPD)))         qpPerPdCnt <- mkCount(fromInteger(valueOf(qpPerPD) - 1));

    Reg#(TestMetaDataSrvState) srvCheckStateReg <- mkReg(TEST_META_DATA_PD_ALLOC);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule reqAllocPDs if (
        !isZero(pdReqCnt) && srvCheckStateReg == TEST_META_DATA_PD_ALLOC
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

    rule respAllocPDs if (srvCheckStateReg == TEST_META_DATA_PD_ALLOC);
        if (isZero(pdRespCnt)) begin
            pdReqCnt  <= fromInteger(pdNum);
            pdRespCnt <= fromInteger(pdNum - 1);
            srvCheckStateReg <= TEST_META_DATA_QP_CREATE;
        end
        else begin
            pdRespCnt.decr(1);
        end

        let maybeAllocRespPD <- metaDataSrv.response.get;
        if (maybeAllocRespPD matches tagged Resp4PD .allocRespPD) begin
            immAssert(
                allocRespPD.successOrNot,
                "allocRespPD.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            pdHandlerQ4Fill.enq(allocRespPD.pdHandler);
            pdHandlerQ4Pop.enq(allocRespPD.pdHandler);
        end
        else begin
            immFail(
                "maybeAllocRespPD assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeAllocRespPD=", fshow(maybeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule

    rule reqCreateQPs if (
        !isZero(qpReqCnt) && srvCheckStateReg == TEST_META_DATA_QP_CREATE
    );
        if (isZero(qpPerPdCnt)) begin
            qpPerPdCnt <= fromInteger(valueOf(qpPerPD) - 1);
            pdHandlerQ4Fill.deq;
        end
        else begin
            qpPerPdCnt.decr(1);
        end
        qpReqCnt.incr(1);

        let pdHandler = pdHandlerQ4Fill.first;

        let createReqQP = ReqQP {
            qpReqType   : REQ_QP_CREATE,
            pdHandler   : pdHandler,
            qpn         : dontCareValue,
            qpAttrMask  : dontCareValue,
            qpAttr      : dontCareValue,
            qpInitAttr  : qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
    endrule

    rule respCreateQPs if (srvCheckStateReg == TEST_META_DATA_QP_CREATE);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            srvCheckStateReg <= TEST_META_DATA_QP_INIT;
        end
        else begin
            qpRespCnt.decr(1);
        end


        let maybeCreateRespQP <- metaDataSrv.response.get;
        if (maybeCreateRespQP matches tagged Resp4QP .createRespQP) begin
            immAssert(
                createRespQP.successOrNot,
                "createRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "createRespQP.successOrNot=", fshow(createRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = createRespQP.qpn;
            qpnQ4Init.enq(qpn);
            qpnQ4RTR.enq(qpn);
            qpnQ4ERR.enq(qpn);
            qpnQ4Destroy.enq(qpn);
            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeCreateRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeCreateRespQP=", fshow(maybeCreateRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqInitQPs if (
        !isZero(qpReqCnt) && srvCheckStateReg == TEST_META_DATA_QP_INIT
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
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP initReqQP);
        // $display(
        //     "time=%0t: reqInitQPs", $time,
        //     ", qpReqCnt=%0d", qpReqCnt
        // );
    endrule

    rule respInitQPs if (srvCheckStateReg == TEST_META_DATA_QP_INIT);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            srvCheckStateReg <= TEST_META_DATA_QP_RTR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeInitRespQP <- metaDataSrv.response.get;
        if (maybeInitRespQP matches tagged Resp4QP .initRespQP) begin
            immAssert(
                initRespQP.successOrNot,
                "initRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "initRespQP.successOrNot=", fshow(initRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            // let qpn = initRespQP.qpn;
            // $display(
            //     "time=%0t: initRespQP=", $time, fshow(initRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h", qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeInitRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeInitRespQP=", fshow(maybeInitRespQP),
                    " should be Resp4QP"
                )
            );
        end

        // $display(
        //     "time=%0t: respInitQPs", $time,
        //     ", qpnQ4RTR.notEmpty=", fshow(qpnQ4RTR.notEmpty),
        //     ", dqpnPipeIn.notEmpty=", fshow(dqpnPipeIn.notEmpty)
        // );
    endrule

    rule reqRtrQPs if (
        !isZero(qpReqCnt) && srvCheckStateReg == TEST_META_DATA_QP_RTR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4RTR.first;
        qpnQ4RTR.deq;

        let qpAttr = qpAttrPipeOut.first;

        qpAttr.dqpn = qpn;
        qpAttr.qpState = IBV_QPS_RTR;
        let setRtrReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP setRtrReqQP);

        $display(
            "time=%0t: reqRtrQPs", $time,
            ", qpReqCnt=%0d", qpReqCnt
        );
    endrule

    rule respRtrQPs if (srvCheckStateReg == TEST_META_DATA_QP_RTR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            srvCheckStateReg <= TEST_META_DATA_QP_ERR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setRtrRespQP) begin
            immAssert(
                setRtrRespQP.successOrNot,
                "setRtrRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "setRtrRespQP.successOrNot=", fshow(setRtrRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setRtrRespQP=", fshow(setRtrRespQP)
                )
            );

            // let sqpn = setRtrRespQP.qpn;
            // let dqpn = setRtrRespQP.qpAttr.dqpn;

            // $display(
            //     "time=%0t: setRtrRespQP=", $time, fshow(setRtrRespQP),
            //     " should be success, and sqpn=%h, dqpn=%h, qpRespCnt=%0d",
            //     sqpn, dqpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqErrQPs if (
        !isZero(qpReqCnt) && srvCheckStateReg == TEST_META_DATA_QP_ERR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4ERR.first;
        qpnQ4ERR.deq;

        let qpAttr = qpAttrPipeOut.first;

        qpAttr.qpState = IBV_QPS_ERR;
        let reqErrQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getOnlyStateRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP reqErrQP);

        // $display("time=%0t: reqRtsQPs, qpReqCnt=%0d", $time, qpReqCnt);
    endrule

    rule respErrQPs if (srvCheckStateReg == TEST_META_DATA_QP_ERR);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            srvCheckStateReg <= TEST_META_DATA_QP_DESTROY;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .respErrQP) begin
            immAssert(
                respErrQP.successOrNot,
                "respErrQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "respErrQP.successOrNot=", fshow(respErrQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", respErrQP=", fshow(respErrQP)
                )
            );

            // $display(
            //     "time=%0t: respErrQP=", $time, fshow(respErrQP),
            //     " should be success, and respErrQP.qpn=%h, qpRespCnt=%h",
            //     respErrQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqDestroyQPs if (!isZero(qpReqCnt) && srvCheckStateReg == TEST_META_DATA_QP_DESTROY);
        qpReqCnt.decr(1);

        let qpn2Destroy = qpnQ4Destroy.first;
        qpnQ4Destroy.deq;

        let destroyReqQP = ReqQP {
            qpReqType : REQ_QP_DESTROY,
            pdHandler : dontCareValue,
            qpn       : qpn2Destroy,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP destroyReqQP);
        // $display("time=%0t: qpn2Destroy=%h", $time, qpn2Destroy);
    endrule

    rule respDestroyQPs if (srvCheckStateReg == TEST_META_DATA_QP_DESTROY);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            srvCheckStateReg <= TEST_META_DATA_PD_DEALLOC;
        end
        else begin
            qpRespCnt.decr(1);
        end

        countDown.decr;

        let maybeDestroyRespQP <- metaDataSrv.response.get;
        if (maybeDestroyRespQP matches tagged Resp4QP .destroyRespQP) begin
            immAssert(
                destroyRespQP.successOrNot,
                "destroyRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "destroyResp.successOrNot=", fshow(destroyRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );
            // $display(
            //     "time=%0t: destroyRespQP=", $time, fshow(destroyRespQP),
            //     " should be success when qpRespCnt=%0d", qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeDestroyRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeDestroyRespQP=", fshow(maybeDestroyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule reqDeallocPDs if (
        !isZero(pdReqCnt) && srvCheckStateReg == TEST_META_DATA_PD_DEALLOC
    );
        pdReqCnt.decr(1);

        let pdHandler2Remove = pdHandlerQ4Pop.first;
        pdHandlerQ4Pop.deq;

        let deAllocReqPD = ReqPD {
            allocOrNot: False,
            pdKey     : dontCareValue,
            pdHandler : pdHandler2Remove
        };
        metaDataSrv.request.put(tagged Req4PD deAllocReqPD);
    endrule

    rule respDeallocPDs if (srvCheckStateReg == TEST_META_DATA_PD_DEALLOC);
        if (isZero(pdRespCnt)) begin
            pdReqCnt  <= fromInteger(pdNum);
            pdRespCnt <= fromInteger(pdNum - 1);
            srvCheckStateReg <= TEST_META_DATA_PD_ALLOC;
        end
        else begin
            pdRespCnt.decr(1);
        end

        let maybeDeAllocRespPD <- metaDataSrv.response.get;
        if (maybeDeAllocRespPD matches tagged Resp4PD .deAllocRespPD) begin
            immAssert(
                deAllocRespPD.successOrNot,
                "deAllocRespPD.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "deAllocRespPD.successOrNot=", fshow(deAllocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            // $display(
            //     "time=%0t: deAllocRespPD=", $time, fshow(deAllocRespPD),
            //     " should be success when pdRespCnt=%0d", pdRespCnt
            // );
        end
        else begin
            immFail(
                "maybeDeAllocRespPD assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeDeAllocRespPD=", fshow(maybeDeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule
endmodule
/*
module mkTestMetaDataSrv2(Empty);
    let pdMetaData  <- mkMetaDataPDs;
    let qpMetaData  <- mkMetaDataQPs;
    let metaDataSrv <- mkMetaDataSrv(pdMetaData, qpMetaData);

    let pdNum = valueOf(MAX_PD);
    let qpNum = valueOf(MAX_QP);
    let qpPerPD = valueOf(TDiv#(MAX_QP, MAX_PD));

    PipeOut#(KeyPD) pdKeyPipeOut <- mkGenericRandomPipeOut;

    FIFOF#(HandlerPD) pdHandlerQ4Fill <- mkSizedFIFOF(pdNum);
    FIFOF#(HandlerPD) pdHandlerQ4Pop  <- mkSizedFIFOF(pdNum);
    FIFOF#(QPN) qpnQ4Modify <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN) qpnQ4Destroy <- mkSizedFIFOF(qpNum);

    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))  pdReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD)))) pdRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))  qpReqCnt <- mkCount(0);
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) qpRespCnt <- mkCount(0);
    Count#(Bit#(TLog#(TDiv#(MAX_QP, MAX_PD)))) qpPerPdCnt <- mkCount(0);

    Reg#(SeqTestState) srvCheckStateReg <- mkReg(TEST_META_DATA_FILL);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule allocPDs if (pdReqCnt < fromInteger(pdNum) && srvCheckStateReg == TEST_META_DATA_FILL);
        pdReqCnt.incr(1);
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

    rule allocRespPDs if (pdRespCnt < fromInteger(pdNum) && srvCheckStateReg == TEST_META_DATA_FILL);
        pdRespCnt.incr(1);
        let maybeAllocRespPD <- metaDataSrv.response.get;
        if (maybeAllocRespPD matches tagged Resp4PD .allocRespPD) begin
            immAssert(
                allocRespPD.successOrNot,
                "allocRespPD.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            pdHandlerQ4Fill.enq(allocRespPD.pdHandler);
            pdHandlerQ4Pop.enq(allocRespPD.pdHandler);
        end
        else begin
            immFail(
                "maybeAllocRespPD assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeAllocRespPD=", fshow(maybeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule

    rule createQPs if (
        pdReqCnt  == fromInteger(pdNum) &&
        pdRespCnt == fromInteger(pdNum) &&
        qpReqCnt   < fromInteger(qpNum) &&
        srvCheckStateReg == TEST_META_DATA_FILL
    );
        if (qpPerPdCnt == fromInteger(qpPerPD - 1)) begin
            qpPerPdCnt <= 0;
            pdHandlerQ4Fill.deq;
        end
        else begin
            qpPerPdCnt.incr(1);
        end
        qpReqCnt.incr(1);

        let pdHandler = pdHandlerQ4Fill.first;

        let createReqQP = ReqQP {
            qpReqType   : REQ_QP_CREATE,
            pdHandler   : pdHandler,
            qpn         : dontCareValue,
            qpAttrMask  : dontCareValue,
            qpAttr      : dontCareValue,
            qpInitAttr  : QpInitAttr {
                qpType  : IBV_QPT_RC,
                sqSigAll: False
            }
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
    endrule

    rule createResp if (
        pdReqCnt  == fromInteger(pdNum) &&
        pdRespCnt == fromInteger(pdNum) &&
        srvCheckStateReg == TEST_META_DATA_FILL
    );
        if (qpRespCnt == fromInteger(qpNum - 1)) begin
            qpReqCnt  <= 0;
            qpRespCnt <= 0;
            srvCheckStateReg <= TEST_META_DATA_ACT;
        end
        else begin
            qpRespCnt.incr(1);
        end

        let maybeCreateRespQP <- metaDataSrv.response.get;
        if (maybeCreateRespQP matches tagged Resp4QP .createRespQP) begin
            immAssert(
                createRespQP.successOrNot,
                "createRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "createRespQP.successOrNot=", fshow(createRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = createRespQP.qpn;
            qpnQ4Modify.enq(qpn);
            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeCreateRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeCreateRespQP=", fshow(maybeCreateRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule modifyQPs if (qpReqCnt < fromInteger(qpNum) && srvCheckStateReg == TEST_META_DATA_ACT);
        qpReqCnt.incr(1);

        let qpn = qpnQ4Modify.first;
        qpnQ4Modify.deq;

        AttrQP qpAttr  = dontCareValue;
        qpAttr.qpState = IBV_QPS_INIT;
        let modifyReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : getReset2InitRequiredAttr,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP modifyReqQP);
    endrule

    rule modifyResp if (srvCheckStateReg == TEST_META_DATA_ACT);
        if (qpRespCnt == fromInteger(qpNum - 1)) begin
            pdReqCnt  <= 0;
            pdRespCnt <= 0;
            qpReqCnt  <= 0;
            qpRespCnt <= 0;
            srvCheckStateReg <= TEST_META_DATA_POP;
        end
        else begin
            qpRespCnt.incr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .modifyRespQP) begin
            immAssert(
                modifyRespQP.successOrNot,
                "modifyRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "modifyRespQP.successOrNot=", fshow(modifyRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = modifyRespQP.qpn;
            qpnQ4Destroy.enq(qpn);
            // $display(
            //     "time=%0t: modifyRespQP=", $time, fshow(modifyRespQP),
            //     " should be success, and qpNum=%0d, qpRespCnt=%h",
            //     qpNum, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule destroyQPs if (qpReqCnt < fromInteger(qpNum) && srvCheckStateReg == TEST_META_DATA_POP);
        qpReqCnt.incr(1);
        let qpn2Destroy = qpnQ4Destroy.first;
        qpnQ4Destroy.deq;

        let destroyReqQP = ReqQP {
            qpReqType : REQ_QP_DESTROY,
            pdHandler : dontCareValue,
            qpn       : qpn2Destroy,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP destroyReqQP);
        // $display("time=%0t: qpn2Destroy=%h", $time, qpn2Destroy);
    endrule

    rule destroyResp if (qpRespCnt < fromInteger(qpNum) && srvCheckStateReg == TEST_META_DATA_POP);
        countDown.decr;
        qpRespCnt.incr(1);

        let maybeDestroyRespQP <- metaDataSrv.response.get;
        if (maybeDestroyRespQP matches tagged Resp4QP .destroyRespQP) begin
            immAssert(
                destroyRespQP.successOrNot,
                "destroyRespQP.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "destroyResp.successOrNot=", fshow(destroyRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );
            // $display(
            //     "time=%0t: destroyRespQP=", $time, fshow(destroyRespQP),
            //     " should be success when qpRespCnt=%0d", qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeDestroyRespQP assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeDestroyRespQP=", fshow(maybeDestroyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    rule deAllocPDs if (
        qpReqCnt  == fromInteger(qpNum) &&
        qpRespCnt == fromInteger(qpNum) &&
        pdReqCnt   < fromInteger(pdNum) &&
        srvCheckStateReg == TEST_META_DATA_POP
    );
        pdReqCnt.incr(1);
        let pdHandler2Remove = pdHandlerQ4Pop.first;
        pdHandlerQ4Pop.deq;

        let deAllocReqPD = ReqPD {
            allocOrNot: False,
            pdKey     : dontCareValue,
            pdHandler : pdHandler2Remove
        };
        metaDataSrv.request.put(tagged Req4PD deAllocReqPD);
    endrule

    rule deAllocResp if (
        qpReqCnt  == fromInteger(qpNum) &&
        qpRespCnt == fromInteger(qpNum) &&
        srvCheckStateReg == TEST_META_DATA_POP
    );
        if (pdRespCnt == fromInteger(pdNum - 1)) begin
            pdReqCnt   <= 0;
            pdRespCnt  <= 0;
            qpReqCnt   <= 0;
            qpRespCnt  <= 0;
            qpPerPdCnt <= 0;
            srvCheckStateReg <= TEST_META_DATA_FILL;
        end
        else begin
            pdRespCnt.incr(1);
        end

        let maybeDeAllocRespPD <- metaDataSrv.response.get;
        if (maybeDeAllocRespPD matches tagged Resp4PD .deAllocRespPD) begin
            immAssert(
                deAllocRespPD.successOrNot,
                "deAllocRespPD.successOrNot assertion @ mkTestMetaDataSrv",
                $format(
                    "deAllocRespPD.successOrNot=", fshow(deAllocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            // $display(
            //     "time=%0t: deAllocRespPD=", $time, fshow(deAllocRespPD),
            //     " should be success when pdRespCnt=%0d", pdRespCnt
            // );
        end
        else begin
            immFail(
                "maybeDeAllocRespPD assertion @ mkTestMetaDataSrv",
                $format(
                    "maybeDeAllocRespPD=", fshow(maybeDeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule
endmodule
*/
