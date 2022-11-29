import Cntrs :: *;
import FIFOF :: *;
import Array :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import ReqGenSQ :: *;
import Settings :: *;
import Utils :: *;

typedef 60000 MAX_CMP_CNT;

interface CountDown;
    method Action dec();
endinterface

module mkCountDown#(Integer maxValue)(CountDown);
    Reg#(Long) cycleNumReg <- mkReg(0);
    let cnt <- mkCount(0);

    rule countCycles;
        cycleNumReg <= cycleNumReg + 1;
    endrule

    method Action dec();
        cnt.incr(1);
        // $display("time=%0d: cycles=%0d, cmp cnt=%0d", $time, cycleNumReg, cnt);

        if (cnt == fromInteger(maxValue)) begin
            $info("time=%0d: finished after %0d cycles", $time, cycleNumReg);
            $finish(0);
        end
    endmethod
endmodule

function Bool filterEmptyDataStream(DataStream ds) = !isZero(ds.byteEn);

function Tuple2#(HeaderByteNum, HeaderBitNum) calcHeaderInvalidByteAndBitNum(
    HeaderByteNum headerLen
);
    HeaderByteNum headerInvalidByteNum =
        fromInteger(valueOf(HEADER_MAX_BYTE_EN_WIDTH)) - headerLen;
    HeaderBitNum headerInvalidBitNum = zeroExtend(headerInvalidByteNum) << 3;

    return tuple2(headerInvalidByteNum, headerInvalidBitNum);
endfunction

function Bool compareRdmaHeaderDataInSim(
    HeaderData headerData, HeaderData refHeaderData, HeaderByteNum headerLen
);
    let { headerInvalidByteNum, headerInvalidBitNum } =
        calcHeaderInvalidByteAndBitNum(headerLen);
    let shiftedHeaderData = headerData >> headerInvalidBitNum;
    let shiftedRefHeaderData = refHeaderData >> headerInvalidBitNum;

    return shiftedHeaderData == shiftedRefHeaderData;
endfunction

// This function should only used in simulation
function ByteEnBitNum calcByteEnBitNumInSim(ByteEn fragByteEn);
    let rightAlignedByteEn = reverseBits(fragByteEn);
    ByteEnBitNum byteEnBitNum = 0;
    // Bool matched = False;
    for (
        Integer idx = 0;
        idx <= valueOf(DATA_BUS_BYTE_WIDTH);
        idx = idx + 1
    ) begin
        if (rightAlignedByteEn == (fromInteger(1) << idx) - 1) begin
            byteEnBitNum = fromInteger(idx);
            // matched = True;
        end
    end
    // $display("matched=%b, rightAlignedByteEn=%h", matched, rightAlignedByteEn);
    return byteEnBitNum;
endfunction

// This function should only used in simulation
function Tuple3#(TotalFragNum, ByteEn, ByteEnBitNum) calcTotalFragNumByLength(Length dmaLen);
    let shiftAmt = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    TotalFragNum fragNum = truncate(dmaLen >> shiftAmt);
    BusByteWidthMask busByteWidthMask = maxBound;
    let lastFragSize = truncate(dmaLen) & busByteWidthMask;
    Bool lastFragEmpty = isZero(lastFragSize);
    if (!lastFragEmpty) begin
        fragNum = fragNum + 1;
    end

    ByteEnBitNum lastFragValidByteNum = lastFragEmpty ?
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) :
        zeroExtend(lastFragSize);
    ByteEn lastFragByteEn = genByteEn(lastFragValidByteNum);
    return tuple3(fragNum, lastFragByteEn, lastFragValidByteNum);
endfunction

function Bool transTypeMatchQpType(TransType tt, QpType qpt);
    return case (tt)
        TRANS_TYPE_CNP: True;
        TRANS_TYPE_RC : (qpt == IBV_QPT_RC);
        TRANS_TYPE_UD : (qpt == IBV_QPT_UD);
        TRANS_TYPE_XRC: (qpt == IBV_QPT_XRC_RECV || qpt == IBV_QPT_XRC_SEND);
        default: False;
    endcase;
endfunction

function Bool rdmaReqOpCodeMatchWorkReqOpCode(RdmaOpCode rdmaOpCode, WorkReqOpCode wrOpCode);
    return case (rdmaOpCode)
        SEND_FIRST, SEND_MIDDLE            : (wrOpCode == IBV_WR_SEND || wrOpCode == IBV_WR_SEND_WITH_IMM || wrOpCode == IBV_WR_SEND_WITH_INV);
        SEND_LAST, SEND_ONLY               : (wrOpCode == IBV_WR_SEND);
        SEND_LAST_WITH_IMMEDIATE,
        SEND_ONLY_WITH_IMMEDIATE           : (wrOpCode == IBV_WR_SEND_WITH_IMM);

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: (wrOpCode == IBV_WR_RDMA_WRITE || wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   : (wrOpCode == IBV_WR_RDMA_WRITE);
        RDMA_WRITE_LAST_WITH_IMMEDIATE,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : (wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);

        RDMA_READ_REQUEST                  : (wrOpCode == IBV_WR_RDMA_READ);
        COMPARE_SWAP                       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP);
        FETCH_ADD                          : (wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);

        SEND_LAST_WITH_INVALIDATE,
        SEND_ONLY_WITH_INVALIDATE          : (wrOpCode == IBV_WR_SEND_WITH_INV);

        default                            : False;
    endcase;
endfunction

function Bool rdmaRespOpCodeMatchWorkReqOpCode(RdmaOpCode rdmaOpCode, WorkReqOpCode wrOpCode);
    case (wrOpCode)
        IBV_WR_RDMA_WRITE            ,
        IBV_WR_RDMA_WRITE_WITH_IMM   ,
        IBV_WR_SEND                  ,
        IBV_WR_SEND_WITH_IMM         ,
        IBV_WR_SEND_WITH_INV         : return rdmaOpCode == ACKNOWLEDGE;
        IBV_WR_RDMA_READ             : return case (rdmaOpCode)
            RDMA_READ_RESPONSE_FIRST ,
            RDMA_READ_RESPONSE_MIDDLE,
            RDMA_READ_RESPONSE_LAST  ,
            RDMA_READ_RESPONSE_ONLY  ,
            ACKNOWLEDGE              : True;
            default                  : False;
        endcase;
        IBV_WR_ATOMIC_CMP_AND_SWP    ,
        IBV_WR_ATOMIC_FETCH_AND_ADD  : return case (rdmaOpCode)
            ACKNOWLEDGE              ,
            ATOMIC_ACKNOWLEDGE       : True;
            default                  : False;
        endcase;
        default                      : return False;
    endcase
endfunction
/*
module mkRandomPipeOut(PipeOut#(anytype)) provisos(Bits#(anytype, tSz), Bounded#(anytype));
    Randomize#(anytype) randomGen <- mkGenericRandomizer;
    FIFOF#(anytype) randomValQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let val <- randomGen.next;
        randomValQ.enq(val);
    endrule

    return convertFifo2PipeOut(randomValQ);
endmodule

module mkRandomFromRangePipeOut#(
    anytype minInclusive, anytype maxInclusive
)(Tuple2#(PipeOut#(anytype), PipeOut#(anytype))) provisos(Bits#(anytype, tSz), Bounded#(anytype));
    FIFOF#(anytype) randomValQ <- mkFIFOF;
    Randomize#(anytype) randomGen <-
        mkConstrainedRandomizer(minInclusive, maxInclusive);
    let tuplePipeOut <- mkForkAndBufferRight(convertFifo2PipeOut(randomValQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule enq if (initializedReg);
        let randomVal <- randomGen.next;
        randomValQ.enq(randomVal);
        // $display("time=%0d: randomVal=%0d", $time, randomVal);
    endrule

    return tuplePipeOut;
endmodule

module mkRandomHeaderDataPipeOut(PipeOut#(HeaderData));
    Randomize#(HeaderData) randomHeaderDataGen <- mkGenericRandomizer;
    FIFOF#(HeaderData) headerDataQ <- mkFIFOF;
    // Vector#(vSz, PipeOut#(HeaderData)) resultPipeOut <-
    //     mkForkVector(convertFifo2PipeOut(headerDataQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomHeaderDataGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let headerData <- randomHeaderDataGen.next;
        headerDataQ.enq(headerData);
    endrule

    return convertFifo2PipeOut(headerDataQ);
endmodule
*/

module mkRandomValueInRangePipeOut#(
    // Both min and max are inclusive
    anytype min, anytype max
)(Vector#(vSz, PipeOut#(anytype))) provisos (Bits#(anytype, aSz), Bounded#(anytype));
    Randomize#(anytype) randomVal <- mkConstrainedRandomizer(min, max);
    FIFOF#(anytype) randomValQ <- mkFIFOF;
    let resultPipeOutVec <- mkForkVector(convertFifo2PipeOut(randomValQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomVal.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let val <- randomVal.next;
        randomValQ.enq(val);
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomLenPipeOut#(
    // Both min and max are inclusive
    Length minLength, Length maxLength
)(PipeOut#(Length));
    Randomize#(Length) randomLen <- mkConstrainedRandomizer(minLength, maxLength);
    FIFOF#(Length) lenQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let len <- randomLen.next;
        // $display(
        //     "time=%0d: generate random len=%0d in range(min=%0d, max=%0d)",
        //     $time, len, minLength, maxLength
        // );
        lenQ.enq(len);
    endrule

    return convertFifo2PipeOut(lenQ);
endmodule

module mkFixedLenHeaderMetaPipeOut#(
    PipeOut#(HeaderByteNum) headerLenPipeIn,
    Bool alwaysHasPayload
)(Vector#(vSz, PipeOut#(HeaderMetaData)));
    FIFOF#(HeaderMetaData) headerMetaDataQ <- mkFIFOF;
    Vector#(vSz, PipeOut#(HeaderMetaData)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(headerMetaDataQ));

    rule enq;
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragValidByeNum(headerLen);
        let headerMetaData = HeaderMetaData {
            headerLen: headerLen,
            headerFragNum: headerFragNum,
            lastFragValidByteNum: headerLastFragValidByteNum,
            // Use the last bit of HeaderLen to randomize hasPayload
            hasPayload: alwaysHasPayload || unpack(headerLen[0])
        };
        headerMetaDataQ.enq(headerMetaData);
        // $display("time=%0d: headerMetaData=", $time, fshow(headerMetaData));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomHeaderMetaPipeOut#(
    HeaderByteNum minHeaderLen,
    HeaderByteNum maxHeaderLen,
    Bool alwaysHasPayload
)(Vector#(vSz, PipeOut#(HeaderMetaData)));
    FIFOF#(HeaderByteNum) headerLenQ <- mkFIFOF;
    Randomize#(HeaderByteNum) randomHeaderLen <-
        mkConstrainedRandomizer(minHeaderLen, maxHeaderLen);
    Vector#(vSz, PipeOut#(HeaderMetaData)) resultPipeOutVec <-
        mkFixedLenHeaderMetaPipeOut(
            convertFifo2PipeOut(headerLenQ),
            alwaysHasPayload
        );

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomHeaderLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule enq if (initializedReg);
        let headerLen <- randomHeaderLen.next;
        headerLenQ.enq(headerLen);
        // $display("time=%0d: headerLen=%0d", $time, headerLen);
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomItemFromVec#(
    Vector#(vSz, anytype) items
)(PipeOut#(anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(vSz), idxSz)
);
    UInt#(idxSz) maxIdx = fromInteger(valueOf(vSz) - 1);
    Vector#(1, PipeOut#(UInt#(idxSz))) vecIdxPipeOut <-
        mkRandomValueInRangePipeOut(0, maxIdx);
    let resultPipeOut <- mkFunc2Pipe(select(items), vecIdxPipeOut[0]);
    return resultPipeOut;
endmodule

module mkRandomWorkReqInRange#(
    Vector#(wrVecSz, WorkReqOpCode) workReqOpCodeVec,
    Length minLength,
    Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    FIFOF#(WorkReq) workReqOutQ <- mkFIFOF;
    let dmaLenPipeOut <- mkRandomLenPipeOut(minLength, maxLength);
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(workReqOutQ));

    rule genWorkReq;
        let dmaLen = dmaLenPipeOut.first;
        dmaLenPipeOut.deq;

        let wrOpCode = workReqOpCodePipeOut.first;
        workReqOpCodePipeOut.deq;

        Long comp = ?;
        Long swap = ?;
        IMM immDt = ?;
        RKEY rkey2Inv = ?;
        QPN srqn = ?;
        QPN dqpn = ?;
        QKEY qkey = ?;
        let workReq = WorkReq {
            id: ?,
            opcode: wrOpCode,
            flags: IBV_SEND_NO_FLAGS,
            raddr: ?,
            rkey: ?,
            len: isAtomicWorkReq(wrOpCode) ? fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)) : dmaLen,
            laddr: ?,
            lkey: ?,
            sqpn: ?,
            solicited: ?,
            comp: workReqHasComp(wrOpCode) ? (tagged Valid comp) : (tagged Invalid),
            swap: workReqHasSwap(wrOpCode) ? (tagged Valid swap) : (tagged Invalid),
            immDt: workReqHasImmDt(wrOpCode) ? (tagged Valid immDt) : (tagged Invalid),
            rkey2Inv: workReqHasInv(wrOpCode) ? (tagged Valid rkey2Inv) : (tagged Invalid),
            srqn: tagged Valid srqn,
            dqpn: tagged Valid dqpn,
            qkey: tagged Valid qkey
        };
        workReqOutQ.enq(workReq);
        // $display("time=%0d: generate random WR=", $time, fshow(workReq));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    WorkReqOpCode workReqOpCodeArray[8] = {
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD,
        IBV_WR_SEND_WITH_INV
    };
    Vector#(8, WorkReqOpCode) workReqOpCodeVec = arrayToVector(workReqOpCodeArray);
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength
    );
    return resultPipeOutVec;
endmodule

module mkSimController#(QpType qpType, PMTU pmtu)(Controller);
    QPN minQPN = 0;
    QPN maxQPN = maxBound;

    let cntlr <- mkController;
    Randomize#(QPN) randomNQPN <- mkConstrainedRandomizer(minQPN, maxQPN);
    Randomize#(QPN) randomEQPN <- mkConstrainedRandomizer(minQPN, maxQPN);
    Reg#(Bool) initializedReg <- mkReg(False);

    rule initRandomizer if (!initializedReg);
        randomNQPN.cntrl.init;
        randomEQPN.cntrl.init;
        initializedReg <= True;
    endrule

    rule initController if (initializedReg && cntlr.getQPS == IBV_QPS_RESET);
        let npsn <- randomNQPN.next;
        let epsn <- randomEQPN.next;
        cntlr.initialize(
            qpType,
            3, // maxRnrCnt
            3, // maxRetryCnt
            1, // maxTimeOut 1 - 8.192 usec (0.000008 sec)
            1, // minRnrTimer 1 - 0.01 milliseconds delay
            fromInteger(valueOf(MAX_PENDING_REQ_NUM)), // pendingWorkReqNum
            fromInteger(valueOf(MAX_PENDING_REQ_NUM)), // pendingRecvReqNum
            True, // sigAll
            ?, // sqpn
            ?, // dqpn
            ?, // pkey
            ?, // qkey
            pmtu,
            npsn,
            epsn
        );
    endrule

    rule setRTR if (initializedReg && cntlr.isInit);
        cntlr.setStateRTR;
    endrule

    rule setRTS if (initializedReg && cntlr.isRTR);
        cntlr.setStateRTS;
    endrule

    return cntlr;
endmodule

module mkNewPendingWorkReqPipeOut#(
    PipeOut#(WorkReq) workReqPipeIn
)(PipeOut#(PendingWorkReq));
    function PendingWorkReq genPendingWorkReq(WorkReq wr) = PendingWorkReq {
        wr: wr,
        startPSN: tagged Invalid,
        endPSN: tagged Invalid,
        pktNum: tagged Invalid,
        isOnlyReqPkt: tagged Invalid
    };

    PipeOut#(PendingWorkReq) resultPipeOut <- mkFunc2Pipe(genPendingWorkReq, workReqPipeIn);
    return resultPipeOut;
endmodule

module mkExistingPendingWorkReqPipeOut#(
    Controller cntlr,
    PipeOut#(WorkReq) workReqPipeIn
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    function ActionValue#(PendingWorkReq) genExistingPendingWorkReq(WorkReq wr);
        actionvalue
            let startPktSeqNum = cntlr.getNPSN;
            let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
                calcPktNumNextAndEndPSN(
                    startPktSeqNum,
                    wr.len,
                    cntlr.getPMTU
                );

            cntlr.setNPSN(nextPktSeqNum);
            let isOnlyReqPkt = isOnlyPkt || isReadWorkReq(wr.opcode);

            return PendingWorkReq {
                wr: wr,
                startPSN: tagged Valid startPktSeqNum,
                endPSN: tagged Valid endPktSeqNum,
                pktNum: tagged Valid totalPktNum,
                isOnlyReqPkt: tagged Valid isOnlyReqPkt
            };
        endactionvalue
    endfunction

    PipeOut#(PendingWorkReq) pendingWorkReqPipeOut <- mkActionValueFunc2Pipe(
        genExistingPendingWorkReq, workReqPipeIn
    );
    Vector#(vSz, PipeOut#(PendingWorkReq)) resultPipeOutVec <-
        mkForkVector(pendingWorkReqPipeOut);
    return resultPipeOutVec;
endmodule
