import Arbitration :: *;
import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;

typedef enum {
    TAG_VEC_RECV_REQ,
    TAG_VEC_RESP_INSERT,
    TAG_VEC_RESP_REMOVE
} TagVecState deriving(Bits, Eq);

interface TagVecSrv#(numeric type vSz, type anytype);
    interface Server#(
        Tuple3#(Bool, anytype, UInt#(TLog#(vSz))),
        Tuple3#(Bool, UInt#(TLog#(vSz)), anytype)
    ) srvPort;
    method Maybe#(anytype) getItem(UInt#(TLog#(vSz)) index);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkTagVecSrv(TagVecSrv#(vSz, anytype)) provisos(
    FShow#(anytype),
    Bits#(anytype, tSz),
    NumAlias#(TLog#(vSz), vLogSz),
    NumAlias#(TAdd#(1, vLogSz), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(vSz, 1))) // vSz must be power of 2
);
    Vector#(vSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Vector#(vSz, Reg#(Bool))     tagVec <- replicateM(mkReg(False));

    FIFOF#(Tuple3#(Bool, anytype, UInt#(TLog#(vSz))))  reqQ <- mkFIFOF;
    FIFOF#(Tuple3#(Bool, UInt#(TLog#(vSz)), anytype)) respQ <- mkFIFOF;

    Reg#(TagVecState) tagVecStateReg <- mkReg(TAG_VEC_RECV_REQ);
    Reg#(Maybe#(UInt#(TLog#(vSz)))) maybeInsertIdxReg <- mkRegU;
    Reg#(Bool) respSuccessReg <- mkRegU;

    Reg#(Bool)    emptyReg <- mkReg(True);
    Reg#(Bool)     fullReg <- mkReg(False);
    Reg#(Bool) clearReg[2] <- mkCReg(2, False);

    Count#(Bit#(cntSz)) itemCnt <- mkCount(0);

    (* no_implicit_conditions, fire_when_enabled *)
    rule clearAll if (clearReg[1]);
        writeVReg(tagVec, replicate(False));
        reqQ.clear;
        respQ.clear;

        tagVecStateReg <= TAG_VEC_RECV_REQ;
        emptyReg       <= True;
        fullReg        <= False;
        clearReg[1]    <= False;
        itemCnt        <= 0;
    endrule

    rule recvReq if (!clearReg[1] && tagVecStateReg == TAG_VEC_RECV_REQ);
        let { insertOrRemove, insertVal, removeIdx } = reqQ.first;
        // reqQ.deq;

        let almostFull  = isAllOnes(removeMSB(itemCnt));
        let almostEmpty = isOne(itemCnt);
        let maybeIndex  = findElem(False, readVReg(tagVec));

        if (insertOrRemove) begin // Insert
            maybeInsertIdxReg <= maybeIndex;

            if (!fullReg) begin
                itemCnt.incr(1);
                emptyReg <= False;
                fullReg <= almostFull;
            end

            respSuccessReg <= !fullReg;
            tagVecStateReg <= TAG_VEC_RESP_INSERT;
        end
        else begin // Remove
            let removeTag = tagVec[removeIdx];

            if (removeTag) begin
                itemCnt.decr(1);
                emptyReg <= almostEmpty;
                fullReg <= False;
            end

            respSuccessReg <= removeTag;
            tagVecStateReg <= TAG_VEC_RESP_REMOVE;
        end
    endrule

    rule genInsertResp if (!clearReg[1] && tagVecStateReg == TAG_VEC_RESP_INSERT);
        let { insertOrRemove, insertVal, removeIdx } = reqQ.first;
        reqQ.deq;

        let insertIdx = dontCareValue;
        if (respSuccessReg) begin
            immAssert(
                isValid(maybeInsertIdxReg),
                "maybeInsertIdxReg assertion @ mkTagVecSrv",
                $format(
                    "maybeInsertIdxReg=", fshow(maybeInsertIdxReg),
                    " should be valid"
                )
            );
            insertIdx = unwrapMaybe(maybeInsertIdxReg);
            tagVec[insertIdx]  <= True;
            dataVec[insertIdx] <= insertVal;
        end

        respQ.enq(tuple3(respSuccessReg, insertIdx, insertVal));
        tagVecStateReg <= TAG_VEC_RECV_REQ;
    endrule

    rule genRemoveResp if (!clearReg[1] && tagVecStateReg == TAG_VEC_RESP_REMOVE);
        let { insertOrRemove, insertVal, removeIdx } = reqQ.first;
        reqQ.deq;

        let removeVal = dataVec[removeIdx];
        tagVec[removeIdx] <= False;

        respQ.enq(tuple3(respSuccessReg, removeIdx, removeVal));
        tagVecStateReg <= TAG_VEC_RECV_REQ;
    endrule

    interface srvPort = toGPServer(reqQ, respQ);

    method Maybe#(anytype) getItem(UInt#(vLogSz) index);
        return (tagVec[index]) ? (tagged Valid dataVec[index]) : (tagged Invalid);
    endmethod

    method Action clear();
        clearReg[0] <= True;
    endmethod

    method Bool notEmpty() = !emptyReg;
    method Bool notFull()  = !fullReg;
endmodule

// MR related

typedef TDiv#(MAX_MR, MAX_PD) MAX_MR_PER_PD;
typedef TLog#(MAX_MR_PER_PD) MR_INDEX_WIDTH;
typedef TSub#(KEY_WIDTH, MR_INDEX_WIDTH) MR_KEY_PART_WIDTH;

typedef UInt#(MR_INDEX_WIDTH) IndexMR;
typedef Bit#(MR_KEY_PART_WIDTH) KeyPartMR;

typedef struct {
    ADDR laddr;
    Length len;
    FlagsType#(MemAccessTypeFlag) accFlags;
    HandlerPD pdHandler;
    KeyPartMR lkeyPart;
    KeyPartMR rkeyPart;
} MemRegion deriving(Bits, FShow);

typedef struct {
    Bool      allocOrNot;
    MemRegion mr;
    Bool      lkeyOrNot;
    LKEY      lkey;
    RKEY      rkey;
} ReqMR deriving(Bits, FShow);

typedef struct {
    Bool      successOrNot;
    MemRegion mr;
    LKEY      lkey;
    RKEY      rkey;
} RespMR deriving(Bits, FShow);

typedef Server#(ReqMR, RespMR) SrvPortMR;

interface MetaDataMRs;
    interface SrvPortMR srvPort;
    method Maybe#(MemRegion) getMemRegionByLKey(LKEY lkey);
    method Maybe#(MemRegion) getMemRegionByRKey(RKEY rkey);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

module mkMetaDataMRs(MetaDataMRs) provisos(
    Add#(TMul#(MAX_MR_PER_PD, MAX_PD), 0, MAX_MR) // MAX_MR == MAX_MR_PER_PD * MAX_PD
);
    TagVecSrv#(MAX_MR_PER_PD, MemRegion) mrTagVec <- mkTagVecSrv;
    // FIFOF#(IndexCB) cbIndexQ <- mkFIFOF;

    function Tuple2#(LKEY, RKEY) genLocalAndRmtKey(IndexMR mrIndex, MemRegion mr);
        LKEY lkey = { pack(mrIndex), mr.lkeyPart };
        RKEY rkey = { pack(mrIndex), mr.rkeyPart };
        return tuple2(lkey, rkey);
    endfunction

    function IndexMR lkey2IndexMR(LKEY lkey) = unpack(truncateLSB(lkey));
    function IndexMR rkey2IndexMR(RKEY rkey) = unpack(truncateLSB(rkey));

    interface srvPort = interface SrvPortMR;
        interface request = interface Put#(ReqMR);
            method Action put(ReqMR mrReq);
                let mrIndex = mrReq.lkeyOrNot ?
                    lkey2IndexMR(mrReq.lkey) : rkey2IndexMR(mrReq.rkey);
                mrTagVec.srvPort.request.put(tuple3(
                    mrReq.allocOrNot, mrReq.mr, mrIndex
                ));
                // cbIndexQ.enq(mrReq.cbIndex);
            endmethod
        endinterface;

        interface response = interface Get#(RespMR);
            method ActionValue#(RespMR) get();
                let { successOrNot, mrIndex, mr } <- mrTagVec.srvPort.response.get;
                // let cbIndex = cbIndexQ.first;
                // cbIndexQ.deq;

                let { lkey, rkey } = genLocalAndRmtKey(mrIndex, mr);
                let mrResp = RespMR {
                    successOrNot: successOrNot,
                    mr          : mr,
                    lkey        : lkey,
                    rkey        : rkey
                    // cbIndex     : cbIndex
                };
                return mrResp;
            endmethod
        endinterface;
    endinterface;

    method Maybe#(MemRegion) getMemRegionByLKey(LKEY lkey);
        IndexMR mrIndex = lkey2IndexMR(lkey);
        return mrTagVec.getItem(mrIndex);
    endmethod

    method Maybe#(MemRegion) getMemRegionByRKey(RKEY rkey);
        IndexMR mrIndex = rkey2IndexMR(rkey);
        return mrTagVec.getItem(mrIndex);
    endmethod

    method Action  clear() = mrTagVec.clear;
    method Bool notEmpty() = mrTagVec.notEmpty;
    method Bool  notFull() = mrTagVec.notFull;
endmodule

// PD related

typedef TLog#(MAX_PD) PD_INDEX_WIDTH;
typedef TSub#(PD_HANDLE_WIDTH, PD_INDEX_WIDTH) PD_KEY_WIDTH;

typedef Bit#(PD_KEY_WIDTH)    KeyPD;
typedef UInt#(PD_INDEX_WIDTH) IndexPD;

typedef struct {
    Bool allocOrNot;
    KeyPD pdKey;
    HandlerPD pdHandler;
} ReqPD deriving(Bits, FShow);

typedef struct {
    Bool successOrNot;
    HandlerPD pdHandler;
    KeyPD pdKey;
} RespPD deriving(Bits, FShow);

typedef Server#(ReqPD, RespPD) SrvPortPD;

interface MetaDataPDs;
    interface SrvPortPD srvPort;
    method Bool isValidPD(HandlerPD pdHandler);
    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function IndexPD getIndexPD(HandlerPD pdHandler) = unpack(truncateLSB(pdHandler));

module mkMetaDataPDs(MetaDataPDs);
    TagVecSrv#(MAX_PD, KeyPD) pdTagVec <- mkTagVecSrv;
    Vector#(MAX_PD, MetaDataMRs) pdMrVec <- replicateM(mkMetaDataMRs);

    function Action clearAllMRs(MetaDataMRs mrMetaData);
        action
            mrMetaData.clear;
        endaction
    endfunction

    interface srvPort = interface SrvPortPD;
        interface request = interface Put#(ReqPD);
            method Action put(ReqPD pdReq);
                IndexPD pdIndex = getIndexPD(pdReq.pdHandler);
                pdTagVec.srvPort.request.put(tuple3(
                    pdReq.allocOrNot, pdReq.pdKey, pdIndex
                ));
            endmethod
        endinterface;

        interface response = interface Get#(RespPD);
            method ActionValue#(RespPD) get();
                let { successOrNot, pdIndex, pdKey } <- pdTagVec.srvPort.response.get;

                HandlerPD pdHandler = { pack(pdIndex), pdKey };
                let pdResp = RespPD {
                    successOrNot: successOrNot,
                    pdHandler   : pdHandler,
                    pdKey       : pdKey
                };
                return pdResp;
            endmethod
        endinterface;
    endinterface;

    method Bool isValidPD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex));
    endmethod

    method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler);
        let pdIndex = getIndexPD(pdHandler);
        return isValid(pdTagVec.getItem(pdIndex)) ?
            (tagged Valid pdMrVec[pdIndex]) : (tagged Invalid);
    endmethod

    method Action clear();
        pdTagVec.clear;
        mapM_(clearAllMRs, pdMrVec);
    endmethod

    method Bool notEmpty() = pdTagVec.notEmpty;
    method Bool notFull()  = pdTagVec.notFull;
endmodule

// QP related

typedef TLog#(MAX_QP) QP_INDEX_WIDTH;
typedef UInt#(QP_INDEX_WIDTH) IndexQP;

interface MetaDataQPs;
    interface SrvPortQP srvPort;
    method Bool isValidQP(QPN qpn);
    method Maybe#(HandlerPD) getPD(QPN qpn);
    method Controller getCntrlByQPN(QPN qpn);
    method Controller getCntrlByIndexQP(IndexQP qpIndex);
    method Action clear();
    method Bool notEmpty();
    method Bool notFull();
endinterface

function IndexQP getIndexQP(QPN qpn) = unpack(truncateLSB(qpn));

function QPN genQPN(IndexQP qpIndex, HandlerPD pdHandler);
    return { pack(qpIndex), truncate(pdHandler) };
endfunction

module mkMetaDataQPs(MetaDataQPs);
    TagVecSrv#(MAX_QP, HandlerPD) qpTagVec <- mkTagVecSrv;
    Vector#(MAX_QP, Controller) qpCntrlVec <- replicateM(mkController);
    FIFOF#(Tuple2#(Bool, ReqQP)) qpReqQ4Resp <- mkFIFOF;
    FIFOF#(ReqQP) qpReqQ4Cntrl <- mkFIFOF;

    rule handleReqQP;
        let qpReq = qpReqQ4Cntrl.first;
        qpReqQ4Cntrl.deq;

        let tagVecRespSuccess = True;
        case (qpReq.qpReqType)
            REQ_QP_CREATE,
            REQ_QP_DESTROY: begin
                let { successOrNot, qpIndex, pdHandler } <- qpTagVec.srvPort.response.get;
                tagVecRespSuccess = successOrNot;
                let cntrl = qpCntrlVec[qpIndex];

                if (tagVecRespSuccess) begin
                    let qpn = genQPN(qpIndex, pdHandler);
                    qpReq.qpn = qpn;
                    qpReq.pdHandler = pdHandler;
                    cntrl.srvPort.request.put(qpReq);
                end
            end
            REQ_QP_MODIFY,
            REQ_QP_QUERY : begin
                let qpIndex = getIndexQP(qpReq.qpn);
                let cntrl = qpCntrlVec[qpIndex];

                cntrl.srvPort.request.put(qpReq);
            end
            default: begin
                immFail(
                    "unreachible case @ mkMetaDataQPs",
                    $format("qpReq.qpReqType=", fshow(qpReq.qpReqType))
                );
            end
        endcase
        qpReqQ4Resp.enq(tuple2(tagVecRespSuccess, qpReq));
    endrule

    interface srvPort = interface SrvPortQP;
        interface request = interface Put#(ReqQP);
            method Action put(ReqQP qpReq);
                case (qpReq.qpReqType)
                    REQ_QP_CREATE ,
                    REQ_QP_DESTROY: begin
                        let qpCreateOrNot = qpReq.qpReqType == REQ_QP_CREATE;
                        let qpIndex = getIndexQP(qpReq.qpn);
                        qpTagVec.srvPort.request.put(tuple3(
                            qpCreateOrNot, qpReq.pdHandler, qpIndex
                        ));
                    end
                    REQ_QP_MODIFY,
                    REQ_QP_QUERY : begin end
                    default: begin
                        immFail(
                            "unreachible case @ mkMetaDataQPs",
                            $format("qpReq.qpReqType=", fshow(qpReq.qpReqType))
                        );
                    end
                endcase

                qpReqQ4Cntrl.enq(qpReq);
            endmethod
        endinterface;

        interface response = interface Get#(RespQP);
            method ActionValue#(RespQP) get();
                let { tagVecRespSuccess, qpReq } = qpReqQ4Resp.first;
                qpReqQ4Resp.deq;

                // immAssert(
                //     tagVecRespSuccess,
                //     "tagVecRespSuccess assertion @ mkMetaDataQPs",
                //     $format(
                //         "tagVecRespSuccess=", fshow(tagVecRespSuccess),
                //         " should be valid when qpReq.qpReqType=", fshow(qpReq.qpReqType),
                //         " and qpReq.qpn=%h", qpReq.qpn
                //     )
                // );

                let qpIndex = getIndexQP(qpReq.qpn);
                let cntrl = qpCntrlVec[qpIndex];
                let qpResp = RespQP {
                    successOrNot: False,
                    qpn         : qpReq.qpn,
                    pdHandler   : qpReq.pdHandler,
                    qpAttr      : qpReq.qpAttr,
                    qpInitAttr  : qpReq.qpInitAttr
                };

                case (qpReq.qpReqType)
                    REQ_QP_CREATE ,
                    REQ_QP_MODIFY ,
                    REQ_QP_QUERY  ,
                    REQ_QP_DESTROY: begin
                        if (tagVecRespSuccess) begin
                            qpResp <- cntrl.srvPort.response.get;
                        end
                    end
                    default: begin
                        immFail(
                            "unreachible case @ mkMetaDataQPs",
                            $format(
                                "request QPN=%h", qpReq.qpn, "qpReqType=", fshow(qpReq.qpReqType)
                            )
                        );
                    end
                endcase

                // $display(
                //     "time=%0t:", $time,
                //     " tagVecRespSuccess=", fshow(tagVecRespSuccess),
                //     " qpResp.successOrNot=", fshow(qpResp.successOrNot),
                //     " qpReq.qpn=%h, qpIndex=%h, qpReq.pdHandler=%h",
                //     qpReq.qpn, qpIndex, qpReq.pdHandler
                // );
                return qpResp;
            endmethod
        endinterface;
    endinterface;

    method Bool isValidQP(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return isValid(qpTagVec.getItem(qpIndex));
    endmethod

    method Maybe#(HandlerPD) getPD(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        return qpTagVec.getItem(qpIndex);
    endmethod

    method Controller getCntrlByQPN(QPN qpn);
        let qpIndex = getIndexQP(qpn);
        let qpCntrl = qpCntrlVec[qpIndex];
        return qpCntrl;
    endmethod

    method Controller getCntrlByIndexQP(IndexQP qpIndex) = qpCntrlVec[qpIndex];

    method Action clear() = qpTagVec.clear;
    method Bool notEmpty() = qpTagVec.notEmpty;
    method Bool notFull()  = qpTagVec.notFull;
endmodule

// MR check related

typedef Server#(PermCheckInfo, Bool) PermCheckMR;

module mkPermCheckMR#(MetaDataPDs pdMetaData)(PermCheckMR);
    FIFOF#(PermCheckInfo) reqInQ <- mkFIFOF;
    FIFOF#(Bool) respOutQ <- mkFIFOF;
    FIFOF#(Tuple3#(PermCheckInfo, Bool, Maybe#(MemRegion))) checkReqQ <- mkFIFOF;

    function Bool checkPermByMR(PermCheckInfo permCheckInfo, MemRegion mr);
        let keyMatch = case (permCheckInfo.localOrRmtKey)
            True : (truncate(permCheckInfo.lkey) == mr.lkeyPart);
            False: (truncate(permCheckInfo.rkey) == mr.rkeyPart);
            // False: (isValid(mr.rkeyPart) ?
            //     truncate(permCheckInfo.rkey) == unwrapMaybe(mr.rkeyPart) : False);
        endcase;

        let accTypeMatch = compareAccessTypeFlags(permCheckInfo.accFlags, mr.accFlags);

        let addrLenMatch = checkAddrAndLenWithinRange(
            permCheckInfo.reqAddr, permCheckInfo.totalLen, mr.laddr, mr.len
        );
        return keyMatch && accTypeMatch && addrLenMatch;
    endfunction

    function Maybe#(MemRegion) mrSearchByLKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, LKEY lkey
    );
        let maybeMR = tagged Invalid;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = mrMetaData.getMemRegionByLKey(lkey);
        end
        return maybeMR;
    endfunction

    function Maybe#(MemRegion) mrSearchByRKey(
        MetaDataPDs pdMetaData, HandlerPD pdHandler, RKEY rkey
    );
        let maybeMR = tagged Invalid;
        let maybeMRs = pdMetaData.getMRs4PD(pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            maybeMR = mrMetaData.getMemRegionByRKey(rkey);
        end
        return maybeMR;
    endfunction

    rule checkReq;
        let permCheckInfo = reqInQ.first;
        reqInQ.deq;

        let isZeroDmaLen = isZero(permCheckInfo.totalLen);
        immAssert(
            !isZeroDmaLen,
            "isZeroDmaLen assertion @ mkPermCheckMR",
            $format(
                "isZeroDmaLen=", fshow(isZeroDmaLen),
                " should be false in PermCheckMR.checkReq()"
            )
        );

        let maybeMR = tagged Invalid;
        if (permCheckInfo.localOrRmtKey) begin
            maybeMR = mrSearchByLKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.lkey
            );
        end
        else begin
            maybeMR = mrSearchByRKey(
                pdMetaData, permCheckInfo.pdHandler, permCheckInfo.rkey
            );
        end

        checkReqQ.enq(tuple3(permCheckInfo, isZeroDmaLen, maybeMR));
    endrule

    rule checkResp;
        let { permCheckInfo, isZeroDmaLen, maybeMR } = checkReqQ.first;
        checkReqQ.deq;

        let checkResult = isZeroDmaLen;
        if (!isZeroDmaLen) begin
            if (maybeMR matches tagged Valid .mr) begin
                checkResult = checkPermByMR(permCheckInfo, mr);
            end
        end

        respOutQ.enq(checkResult);
    endrule

    return toGPServer(reqInQ, respOutQ);
endmodule

typedef Vector#(portSz, PermCheckMR) PermCheckArbiter#(numeric type portSz);

module mkPermCheckAribter#(PermCheckMR permCheckMR)(PermCheckArbiter#(portSz)) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isPermCheckReqFinished(PermCheckInfo req) = True;
    function Bool isPermCheckRespFinished(Bool resp) = True;

    PermCheckArbiter#(portSz) arbiter <- mkServerArbiter(
        permCheckMR,
        isPermCheckReqFinished,
        isPermCheckRespFinished
    );
    return arbiter;
endmodule

// MetaDataSrv related

typedef enum {
    META_DATA_RECV_REQ,
    META_DATA_MR_REQ,
    META_DATA_PD_REQ,
    META_DATA_QP_REQ,
    META_DATA_MR_RESP,
    META_DATA_PD_RESP,
    META_DATA_QP_RESP
} MetaDataSrvState deriving(Bits, Eq);

typedef union tagged {
    ReqPD Req4PD;
    ReqMR Req4MR;
    ReqQP Req4QP;
} MetaDataReq deriving(Bits, FShow);

typedef union tagged {
    RespPD Resp4PD;
    RespMR Resp4MR;
    RespQP Resp4QP;
} MetaDataResp deriving(Bits, FShow);

typedef Server#(MetaDataReq, MetaDataResp) MetaDataSrv;

// TODO: check PD can be deallocated before removing all associated QPs
module mkMetaDataSrv#(
    MetaDataPDs pdMetaData, MetaDataQPs qpMetaData
)(MetaDataSrv) provisos(
    Add#(MAX_PD, anysizeJ, MAX_QP), // MAX_QP >= MAX_PD
    NumAlias#(TDiv#(MAX_QP, MAX_PD), qpPerPD),
    Add#(1, anysizeK, qpPerPD), // qpPerPD > 1
    Add#(TMul#(MAX_PD, qpPerPD), 0, MAX_QP) // MAX_QP == MAX_PD * qpPerPD
);
    FIFOF#(MetaDataReq)   metaDataReqQ <- mkFIFOF;
    FIFOF#(MetaDataResp) metaDataRespQ <- mkFIFOF;

    Reg#(ReqMR) mrReqReg <- mkRegU;
    Reg#(ReqPD) pdReqReg <- mkRegU;
    Reg#(ReqQP) qpReqReg <- mkRegU;
    Reg#(MetaDataSrvState) stateReg <- mkReg(META_DATA_RECV_REQ);
/*
    rule issueMetaDataReq if (stateReg == META_DATA_RECV_REQ);
        let metaDataReq = metaDataReqQ.first;
        metaDataReqQ.deq;

        case (metaDataReq) matches
            tagged Req4MR .mrReq: begin
                let pdIndex = getIndexPD(mrReq.mr.pdHandler);
                let maybeMRs = pdMetaData.getMRs4PD(mrReq.mr.pdHandler);
                if (maybeMRs matches tagged Valid .mrMetaData) begin
                    mrMetaData.srvPort.request.put(mrReq);
                end
                mrReqReg <= mrReq;
                stateReg <= META_DATA_MR_RESP;
            end
            tagged Req4PD .pdReq: begin
                pdMetaData.srvPort.request.put(pdReq);
                pdReqReg <= pdReq;
                stateReg <= META_DATA_PD_RESP;
            end
            tagged Req4QP .qpReq: begin
                let isValidPD = pdMetaData.isValidPD(qpReq.pdHandler);
                if (isValidPD) begin
                    qpMetaData.srvPort.request.put(qpReq);
                end
                qpReqReg <= qpReq;
                stateReg <= META_DATA_QP_RESP;
            end
        endcase
        // busyReg <= True;
    endrule
*/
    // Do not use pipeline to avoid conflict requests
    rule recvMetaDataReq if (stateReg == META_DATA_RECV_REQ);
        let metaDataReq = metaDataReqQ.first;
        metaDataReqQ.deq;

        case (metaDataReq) matches
            tagged Req4MR .mrReq: begin
                mrReqReg <= mrReq;
                stateReg <= META_DATA_MR_REQ;
            end
            tagged Req4PD .pdReq: begin
                pdReqReg <= pdReq;
                stateReg <= META_DATA_PD_REQ;
            end
            tagged Req4QP .qpReq: begin
                qpReqReg <= qpReq;
                stateReg <= META_DATA_QP_REQ;
            end
        endcase
    endrule

    rule issueReq4MR if (stateReg == META_DATA_MR_REQ);
        let mrReq = mrReqReg;
        let pdIndex = getIndexPD(mrReq.mr.pdHandler);
        let maybeMRs = pdMetaData.getMRs4PD(mrReq.mr.pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            mrMetaData.srvPort.request.put(mrReq);
        end
        stateReg <= META_DATA_MR_RESP;
    endrule

    rule issueReq4PD if (stateReg == META_DATA_PD_REQ);
        let pdReq = pdReqReg;
        pdMetaData.srvPort.request.put(pdReq);
        stateReg <= META_DATA_PD_RESP;
    endrule

    rule issueReq4QP if (stateReg == META_DATA_QP_REQ);
        let qpReq = qpReqReg;
        let isValidPD = pdMetaData.isValidPD(qpReq.pdHandler);
        if (isValidPD) begin
            qpMetaData.srvPort.request.put(qpReq);
        end
        stateReg <= META_DATA_QP_RESP;
    endrule

    rule genResp4MR if (stateReg == META_DATA_MR_RESP);
        let mrReq = mrReqReg;
        let mrResp = RespMR {
            successOrNot: False,
            mr          : mrReq.mr,
            lkey        : mrReq.lkey,
            rkey        : mrReq.rkey
        };

        let pdIndex = getIndexPD(mrReq.mr.pdHandler);
        let maybeMRs = pdMetaData.getMRs4PD(mrReq.mr.pdHandler);
        if (maybeMRs matches tagged Valid .mrMetaData) begin
            mrResp <- mrMetaData.srvPort.response.get;
        end

        metaDataRespQ.enq(tagged Resp4MR mrResp);
        stateReg <= META_DATA_RECV_REQ;
    endrule

    rule genResp4PD if (stateReg == META_DATA_PD_RESP);
        let pdReq = pdReqReg;
        let pdResp <- pdMetaData.srvPort.response.get;

        metaDataRespQ.enq(tagged Resp4PD pdResp);
        stateReg <= META_DATA_RECV_REQ;
    endrule

    rule genResp4QP if (stateReg == META_DATA_QP_RESP);
        let qpReq = qpReqReg;
        let qpResp = RespQP {
            successOrNot: False,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        let isValidPD = pdMetaData.isValidPD(qpReq.pdHandler);
        if (isValidPD) begin
            qpResp <- qpMetaData.srvPort.response.get;
        end

        metaDataRespQ.enq(tagged Resp4QP qpResp);
        stateReg <= META_DATA_RECV_REQ;
    endrule

    return toGPServer(metaDataReqQ, metaDataRespQ);
endmodule

// TLB related

typedef TExp#(11)  BRAM_CACHE_SIZE; // 2K
typedef BYTE_WIDTH BRAM_CACHE_DATA_WIDTH;

typedef Bit#(TLog#(BRAM_CACHE_SIZE)) BramCacheAddr;
typedef Bit#(BRAM_CACHE_DATA_WIDTH)  BramCacheData;

typedef Server#(BramCacheAddr, BramCacheData) BramRead;

interface BramCache;
    interface BramRead read;
    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
endinterface

// BramCache total size 2K * 8 = 16Kb
module mkBramCache(BramCache);
    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(BramCacheAddr, BramCacheData) bram2Port <- mkBRAM2Server(cfg);

    FIFOF#(BramCacheAddr)  bramReadReqQ <- mkFIFOF;
    FIFOF#(BramCacheData) bramReadRespQ <- mkFIFOF;

    rule handleBramReadReq;
        let cacheAddr = bramReadReqQ.first;
        bramReadReqQ.deq;

        let req = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: cacheAddr,
            datain: dontCareValue
        };
        bram2Port.portA.request.put(req);
    endrule

    rule handleBramReadResp;
        let readRespData <- bram2Port.portA.response.get;
        bramReadRespQ.enq(readRespData);
    endrule

    method Action write(BramCacheAddr cacheAddr, BramCacheData writeData);
        let req = BRAMRequest{
            write: True,
            responseOnWrite: False,
            address: cacheAddr,
            datain: writeData
        };
        bram2Port.portB.request.put(req);
    endmethod

    interface read = toGPServer(bramReadReqQ, bramReadRespQ);
endmodule

interface CascadeCache#(numeric type addrWidth, numeric type payloadWidth);
    interface Server#(Bit#(addrWidth), Bit#(payloadWidth)) read;
    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
endinterface

module mkCascadeCache(CascadeCache#(addrWidth, payloadWidth)) provisos(
    NumAlias#(TLog#(BRAM_CACHE_SIZE), bramCacheIndexWidth),
    Add#(bramCacheIndexWidth, TAdd#(anysize, 1), addrWidth), // addrWidth > bramCacheIndexWidth
    NumAlias#(TDiv#(payloadWidth, BRAM_CACHE_DATA_WIDTH), colNum),
    Add#(TMul#(BRAM_CACHE_DATA_WIDTH, colNum), 0, payloadWidth), // payloadWidth must be multiplier of BYTE_WIDTH
    NumAlias#(TSub#(addrWidth, bramCacheIndexWidth), cascadeCacheIndexWidth),
    NumAlias#(TExp#(cascadeCacheIndexWidth), rowNum)
);
    function BramCacheAddr getBramCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncate(cacheAddr); // [valueOf(bramCacheIndexWidth) - 1 : 0];
    endfunction

    function Bit#(cascadeCacheIndexWidth) getCascadeCacheIndex(Bit#(addrWidth) cacheAddr);
        return truncateLSB(cacheAddr); // [valueOf(addrWidth) - 1 : valueOf(bramCacheIndexWidth)];
    endfunction

    function Action readReqHelper(BramCacheAddr bramCacheIndex, BramCache bramCache);
        action
            bramCache.read.request.put(bramCacheIndex);
        endaction
    endfunction

    function ActionValue#(BramCacheData) readRespHelper(BramCache bramCache);
        actionvalue
            let bramCacheReadRespData <- bramCache.read.response.get;
            return bramCacheReadRespData;
        endactionvalue
    endfunction

    function Action writeHelper(
        BramCacheAddr bramCacheIndex, Tuple2#(BramCache, BramCacheData) tupleInput
    );
        action
            let { bramCache, writeData } = tupleInput;
            bramCache.write(bramCacheIndex, writeData);
        endaction
    endfunction

    function Bit#(payloadWidth) concatBitVec(BramCacheData bramCacheData, Bit#(payloadWidth) concatResult);
        return truncate({ concatResult, bramCacheData });
    endfunction
    // function Bit#(m) concatBitVec(Vector#(nSz, Bit#(n)) inputBitVec) provisos(
    //     Add#(TMul#(n, nSz), 0, m)
    // );
    //     Bit#(m) result = dontCareValue;
    //     for (Integer idx = 0; idx < valueOf(n); idx = idx + 1) begin
    //         // result[(idx+1)*valueOf(n) : idx*valueOf(n)] = inputBitVec[idx];
    //         result = truncate({ result, inputBitVec[idx] });
    //     end
    //     return result;
    // endfunction

    Vector#(rowNum, Vector#(colNum, BramCache)) cascadeCacheVec <- replicateM(replicateM(mkBramCache));
    FIFOF#(Bit#(cascadeCacheIndexWidth)) cascadeCacheIndexQ <- mkFIFOF;
    FIFOF#(Bit#(addrWidth)) cacheReadReqQ <- mkFIFOF;
    FIFOF#(Bit#(payloadWidth)) cacheReadRespQ <- mkFIFOF;

    rule handleCacheReadReq;
        let cacheAddr = cacheReadReqQ.first;
        cacheReadReqQ.deq;

        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        mapM_(readReqHelper(bramCacheIndex), cascadeCacheVec[cascadeCacheIndex]);
        cascadeCacheIndexQ.enq(cascadeCacheIndex);
    endrule

    rule handleCacheReadResp;
        let cascadeCacheIndex = cascadeCacheIndexQ.first;
        cascadeCacheIndexQ.deq;
        Vector#(colNum, BramCacheData) bramCacheReadRespVec <- mapM(
            readRespHelper, cascadeCacheVec[cascadeCacheIndex]
        );
        Bit#(payloadWidth) concatSeed = dontCareValue;
        Bit#(payloadWidth) concatResult = foldr(concatBitVec, concatSeed, bramCacheReadRespVec);

        cacheReadRespQ.enq(concatResult);
    endrule

    method Action write(Bit#(addrWidth) cacheAddr, Bit#(payloadWidth) writeData);
        let cascadeCacheIndex = getCascadeCacheIndex(cacheAddr);
        let bramCacheIndex = getBramCacheIndex(cacheAddr);

        Vector#(colNum, BramCacheData) writeDataVec = toChunks(writeData);
        Vector#(colNum, Tuple2#(BramCache, BramCacheData)) bramCacheAndWriteDataVec = zip(
            cascadeCacheVec[cascadeCacheIndex], writeDataVec
        );
        mapM_(writeHelper(bramCacheIndex), bramCacheAndWriteDataVec);
    endmethod

    interface read = toGPServer(cacheReadReqQ, cacheReadRespQ);
endmodule

typedef Tuple2#(Bool, ADDR) FindRespTLB;
typedef Server#(ADDR, FindRespTLB) FindInTLB;

interface TLB;
    interface FindInTLB find;
    method Action insert(ADDR va, ADDR pa);
    // TODO: implement delete method
    // method Action delete(ADDR va);
endinterface

function Bit#(PAGE_OFFSET_WIDTH) getPageOffset(ADDR addr);
    return truncate(addr);
endfunction

function ADDR restorePA(
    Bit#(TLB_CACHE_PA_DATA_WIDTH) paData, Bit#(PAGE_OFFSET_WIDTH) pageOffset
);
    return signExtend({ paData, pageOffset });
endfunction

function Bit#(TLB_CACHE_PA_DATA_WIDTH) getData4PA(ADDR pa);
    return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
endfunction

module mkTLB(TLB);
    CascadeCache#(TLB_CACHE_INDEX_WIDTH, TLB_PAYLOAD_WIDTH) cache4TLB <- mkCascadeCache;
    FIFOF#(ADDR) vaInputQ <- mkFIFOF;
    FIFOF#(ADDR) findReqQ <- mkFIFOF;
    FIFOF#(FindRespTLB) findRespQ <- mkFIFOF;

    function Bit#(TLB_CACHE_INDEX_WIDTH) getIndex4TLB(ADDR va);
        return truncate(va >> valueOf(PAGE_OFFSET_WIDTH));
    endfunction

    function Bit#(TLB_CACHE_TAG_WIDTH) getTag4TLB(ADDR va);
        return truncate(va >> valueOf(TAdd#(TLB_CACHE_INDEX_WIDTH, PAGE_OFFSET_WIDTH)));
    endfunction

    rule handleFindReq;
        let va = findReqQ.first;
        findReqQ.deq;

        let index = getIndex4TLB(va);
        cache4TLB.read.request.put(index);

        vaInputQ.enq(va);
    endrule

    rule handleFindResp;
        let va = vaInputQ.first;
        vaInputQ.deq;

        let inputTag = getTag4TLB(va);
        let pageOffset = getPageOffset(va);

        let readRespData <- cache4TLB.read.response.get;
        PayloadTLB payload = unpack(readRespData);

        let pa = restorePA(payload.data, pageOffset);
        let tagMatch = inputTag == payload.tag;

        findRespQ.enq(tuple2(tagMatch, pa));
    endrule

    method Action insert(ADDR va, ADDR pa);
        let index = getIndex4TLB(va);
        let inputTag = getTag4TLB(va);
        let paData = getData4PA(pa);
        let payload = PayloadTLB {
            data: paData,
            tag : inputTag
        };
        cache4TLB.write(index, pack(payload));
    endmethod

    interface find = toGPServer(findReqQ, findRespQ);
endmodule
