import Array :: *;
import BuildVector :: *;
import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import Settings :: *;
import Utils :: *;

typedef 0 DEFAULT_QPN;
typedef 0 DEFAULT_QP_IDX;
typedef 3 DEFAULT_RETRY_NUM;
typedef 10000 MAX_CMP_CNT;

function QPN getDefaultQPN();
    return fromInteger(valueOf(DEFAULT_QPN));
endfunction

function IndexQP getDefaultIndexQP();
    return fromInteger(valueOf(DEFAULT_QP_IDX));
endfunction

interface CountDown;
    method Action decr();
    method int   _read();
endinterface

module mkCountDown#(Integer maxValue)(CountDown);
    Reg#(Long) cycleNumReg <- mkReg(0);
    Count#(int) cnt <- mkCount(fromInteger(maxValue));

    rule countCycles;
        cycleNumReg <= cycleNumReg + 1;
    endrule

    method Action decr();
        cnt.decr(1);
        // $display("time=%0t: cycles=%0d, cmp cnt=%0d", $time, cycleNumReg, cnt);

        if (isZero(pack(cnt))) begin
            $info("time=%0t: finished after %0d cycles", $time, cycleNumReg);
            $finish(0);
        end
    endmethod

    method int _read() = cnt;
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

// This function should be used in simulation only
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

// This function should be used in simulation only
function Tuple3#(TotalFragNum, ByteEn, ByteEnBitNum) calcTotalFragNumByLength(Length dmaLen);
    Bit#(DATA_BUS_BYTE_NUM_WIDTH) lastFragByteNumResidue = truncate(dmaLen);
    Bit#(TSub#(RDMA_MAX_LEN_WIDTH, DATA_BUS_BYTE_NUM_WIDTH)) truncatedLen = truncateLSB(dmaLen);
    let lastFragEmpty = isZero(lastFragByteNumResidue);
    TotalFragNum fragNum = zeroExtend(truncatedLen + zeroExtend(pack(!lastFragEmpty)));

    // let shiftAmt = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    // TotalFragNum fragNum = truncate(dmaLen >> shiftAmt);
    // BusByteWidthMask busByteWidthMask = maxBound;
    // let lastFragSize = truncate(dmaLen) & busByteWidthMask;
    // Bool lastFragEmpty = isZero(lastFragSize);
    // if (!lastFragEmpty) begin
    //     fragNum = fragNum + 1;
    // end

    ByteEnBitNum lastFragValidByteNum = lastFragEmpty ?
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) :
        zeroExtend(lastFragByteNumResidue);
    ByteEn lastFragByteEn = genByteEn(lastFragValidByteNum);
    return tuple3(fragNum, lastFragByteEn, lastFragValidByteNum);
endfunction

// This function should be used in simulation only
function PktNum calcPktNumByLenOnly(Length len, PMTU pmtu);
    return case (pmtu)
        IBV_MTU_256 : begin
            Bit#(8) residue = truncate(len); // [7 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) truncatedLen = truncateLSB(len);
            zeroExtend(truncatedLen + (isZero(residue) ? 0 : 1));
        end
        IBV_MTU_512 : begin
            Bit#(9) residue = truncate(len); // [8 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) truncatedLen = truncateLSB(len);
            zeroExtend(truncatedLen + (isZero(residue) ? 0 : 1));
        end
        IBV_MTU_1024: begin
            Bit#(10) residue = truncate(len); // [9 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) truncatedLen = truncateLSB(len);
            zeroExtend(truncatedLen + (isZero(residue) ? 0 : 1));
        end
        IBV_MTU_2048: begin
            Bit#(11) residue = truncate(len); // [10 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) truncatedLen = truncateLSB(len);
            zeroExtend(truncatedLen + (isZero(residue) ? 0 : 1));
        end
        IBV_MTU_4096: begin
            Bit#(12) residue = truncate(len); // [11 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) truncatedLen = truncateLSB(len);
            zeroExtend(truncatedLen + (isZero(residue) ? 0 : 1));
        end
    endcase;
endfunction

// This function should be used in simulation only
function Tuple2#(Bool, PktNum) calcPktNumByLength(Length len, PMTU pmtu);
    let pktNum = calcPktNumByLenOnly(len, pmtu);

    // In case zero length, it is also only packet
    let isOnlyPkt = isLessOrEqOne(pktNum);
    return tuple2(isOnlyPkt, pktNum);
endfunction

// This function should be used in simulation only
function Tuple4#(Bool, PktNum, PSN, PSN) calcPktNumNextAndEndPSN(
    PSN startPSN, Length len, PMTU pmtu
);
    let { isOnlyPkt, pktNum } = calcPktNumByLength(len, pmtu);
    PSN nextPSN = truncate(zeroExtend(startPSN) + pktNum); // zeroExtend(pktNum);
    PSN endPSN = startPSN;
    if (!isOnlyPkt) begin
        endPSN = nextPSN - 1;
    end
    else begin // zero length
        nextPSN = endPSN + 1;
    end
    return tuple4(isOnlyPkt, pktNum, nextPSN, endPSN);
endfunction

// This module should be used in simulation only
module mkSegmentDataStreamByPmtu#(
    DataStreamPipeOut dataStreamPipeIn,
    PipeOut#(PMTU) pmtuPipeIn
)(DataStreamPipeOut);
    Reg#(PmtuFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PmtuFragNum) fragCntReg <- mkRegU;
    FIFOF#(DataStream) dataQ <- mkFIFOF;
    Reg#(Bool) setFirstReg <- mkReg(False);

    rule segment;
        let curData = dataStreamPipeIn.first;
        dataStreamPipeIn.deq;
        Bool isFragCntZero = isZero(fragCntReg);

        if (!setFirstReg && curData.isFirst) begin
            let pmtu = pmtuPipeIn.first;
            pmtuPipeIn.deq;
            let pmtuFragNum = calcFragNumByPmtu(pmtu);
            pmtuFragNumReg <= pmtuFragNum;
            fragCntReg <= pmtuFragNum - 2;
        end
        else if (setFirstReg) begin
            curData.isFirst = True;
            setFirstReg <= False;
            fragCntReg <= pmtuFragNumReg - 2;
        end
        else if (isFragCntZero) begin
            curData.isLast = True;
            setFirstReg <= True;
        end
        else if (!curData.isLast) begin
            fragCntReg <= fragCntReg - 1;
        end

        dataQ.enq(curData);
    endrule

    method DataStream first() = dataQ.first;
    method Action deq() = dataQ.deq;
    method Bool notEmpty() = dataQ.notEmpty;
endmodule

// This function should be used in simulation only
function ByteEn addPadding2LastFragByteEn(ByteEn lastFragByteEn);
    let lastFragValidByteNum = calcByteEnBitNumInSim(lastFragByteEn);
    let padCnt = calcPadCnt(zeroExtend(lastFragValidByteNum));
    let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
    let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
    return lastFragByteEnWithPadding;
endfunction

// This module should be used in simulation only
module mkSegmentDataStreamByPmtuAndAddPadCnt#(
    DataStreamPipeOut dataStreamPipeIn,
    PipeOut#(PMTU) pmtuPipeIn
)(DataStreamPipeOut);
    function DataStream addPadding(DataStream inputDataStream);
        if (inputDataStream.isLast) begin
            let lastFragByteEnWithPadding = addPadding2LastFragByteEn(
                inputDataStream.byteEn
            );
            // $display(
            //     "time=%0t: inputDataStream.byteEn=%h, padCnt=%0d",
            //     $time, inputDataStream.byteEn, padCnt
            // );
            inputDataStream.byteEn = lastFragByteEnWithPadding;
        end

        return inputDataStream;
    endfunction

    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        dataStreamPipeIn, pmtuPipeIn
    );

    let resultPipeOut <- mkFunc2Pipe(addPadding, segDataStreamPipeOut);
    return resultPipeOut;
endmodule

// Random PipeOut related

module mkGenericRandomPipeOut(PipeOut#(anytype)) provisos(
    Bits#(anytype, tSz), Bounded#(anytype)
);
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

module mkGenericRandomPipeOutVec(
    Vector#(vSz, PipeOut#(anytype))
) provisos(Bits#(anytype, tSz), Bounded#(anytype));
    PipeOut#(anytype) resultPipeOut <- mkGenericRandomPipeOut;
    Vector#(vSz, PipeOut#(anytype)) resultPipeOutVec <-
        mkForkVector(resultPipeOut);
    return resultPipeOutVec;
endmodule

module mkRandomValueInRangePipeOut#(
    // Both min and max are inclusive
    anytype min, anytype max
)(Vector#(vSz, PipeOut#(anytype))) provisos(
    Bits#(anytype, tSz), Bounded#(anytype), FShow#(anytype), Ord#(anytype)
);
    Randomize#(anytype) randomVal <- mkConstrainedRandomizer(min, max);
    FIFOF#(anytype) randomValQ <- mkFIFOF;
    let resultPipeOutVec <- mkForkVector(convertFifo2PipeOut(randomValQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        immAssert(
            max >= min,
            "max >= min assertion @",
            $format(
                "max=", fshow(max), " should >= min=", fshow(min)
            )
        );
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
        immAssert(
            maxLength >= minLength,
            "maxLength >= minLength assertion @",
            $format(
                "maxLength=%h should >= minLength=%h", minLength, maxLength
            )
        );
        randomLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let len <- randomLen.next;
        // $display(
        //     "time=%0t: generate random len=%0d in range(min=%0d, max=%0d)",
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
        // $display("time=%0t: headerMetaData=", $time, fshow(headerMetaData));
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
        // $display("time=%0t: headerLen=%0d", $time, headerLen);
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

module mkRandomAtomicReqRdmaOpCode(PipeOut#(RdmaOpCode));
    Vector#(2, RdmaOpCode) atomicOpCodeVec = vec(COMPARE_SWAP, FETCH_ADD);
    PipeOut#(RdmaOpCode) resultPipeOut <- mkRandomItemFromVec(atomicOpCodeVec);
    return resultPipeOut;
endmodule

module mkRandomAtomicWorkReqOpCode(PipeOut#(WorkReqOpCode));
    Vector#(2, WorkReqOpCode) atomicOpCodeVec = vec(
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD
    );

    PipeOut#(WorkReqOpCode) resultPipeOut <- mkRandomItemFromVec(atomicOpCodeVec);
    return resultPipeOut;
endmodule

// WorkReq check related

function Bool rdmaReqOpCodeMatchWorkReqOpCode(RdmaOpCode rdmaOpCode, WorkReqOpCode wrOpCode);
    return case (rdmaOpCode)
        SEND_FIRST, SEND_MIDDLE            : (wrOpCode == IBV_WR_SEND || wrOpCode == IBV_WR_SEND_WITH_IMM || wrOpCode == IBV_WR_SEND_WITH_INV);
        SEND_LAST, SEND_ONLY               : (wrOpCode == IBV_WR_SEND);
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           : (wrOpCode == IBV_WR_SEND_WITH_IMM);

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: (wrOpCode == IBV_WR_RDMA_WRITE || wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   : (wrOpCode == IBV_WR_RDMA_WRITE);
        RDMA_WRITE_LAST_WITH_IMMEDIATE     ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : (wrOpCode == IBV_WR_RDMA_WRITE_WITH_IMM);

        RDMA_READ_REQUEST                  : (wrOpCode == IBV_WR_RDMA_READ);
        COMPARE_SWAP                       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP);
        FETCH_ADD                          : (wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);

        SEND_LAST_WITH_INVALIDATE          ,
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

function Bool workCompMatchWorkReqInSQ(WorkComp wc, WorkReq wr);
    return wc.id == wr.id && case (wr.opcode)
        IBV_WR_RDMA_WRITE          : (wc.opcode == IBV_WC_RDMA_WRITE);
        IBV_WR_RDMA_WRITE_WITH_IMM : (wc.opcode == IBV_WC_RDMA_WRITE);
        IBV_WR_SEND                : (wc.opcode == IBV_WC_SEND);
        IBV_WR_SEND_WITH_IMM       : (wc.opcode == IBV_WC_SEND);
        IBV_WR_RDMA_READ           : (wc.opcode == IBV_WC_RDMA_READ);
        IBV_WR_ATOMIC_CMP_AND_SWP  : (wc.opcode == IBV_WC_COMP_SWAP);
        IBV_WR_ATOMIC_FETCH_AND_ADD: (wc.opcode == IBV_WC_FETCH_ADD);
        IBV_WR_LOCAL_INV           : (wc.opcode == IBV_WC_LOCAL_INV);
        IBV_WR_BIND_MW             : (wc.opcode == IBV_WC_BIND_MW);
        IBV_WR_SEND_WITH_INV       : (wc.opcode == IBV_WC_SEND);
        IBV_WR_TSO                 : (wc.opcode == IBV_WC_TSO);
        IBV_WR_DRIVER1             : (wc.opcode == IBV_WC_DRIVER1);
        default                    : False;
    endcase;
endfunction

function Bool workCompMatchWorkReqInRQ(WorkComp wc, WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM : (wc.opcode == IBV_WC_RECV_RDMA_WITH_IMM && containWorkCompFlag(wc.flags, IBV_WC_WITH_IMM));
        IBV_WR_SEND                : (wc.opcode == IBV_WC_RECV);
        IBV_WR_SEND_WITH_IMM       : (wc.opcode == IBV_WC_RECV && containWorkCompFlag(wc.flags, IBV_WC_WITH_IMM));
        IBV_WR_SEND_WITH_INV       : (wc.opcode == IBV_WC_RECV && containWorkCompFlag(wc.flags, IBV_WC_WITH_INV));
        default                    : False;
    endcase;
endfunction

function Bool isFatalErrAETH(AETH aeth);
    case (aeth.code)
        // AETH_CODE_ACK: return tagged Valid IBV_WC_SUCCESS;
        // AETH_CODE_RNR: return tagged Valid IBV_WC_RNR_RETRY_EXC_ERR;
        AETH_CODE_NAK: return case (aeth.value)
            // zeroExtend(pack(AETH_NAK_SEQ_ERR)): tagged Valid IBV_WC_RETRY_EXC_ERR;
            zeroExtend(pack(AETH_NAK_INV_REQ)),
            zeroExtend(pack(AETH_NAK_RMT_ACC)),
            zeroExtend(pack(AETH_NAK_RMT_OP)) ,
            zeroExtend(pack(AETH_NAK_INV_RD)) : True;
            default                           : False;
        endcase;
        // AETH_CODE_RSVD
        default: return False;
    endcase
endfunction

// WorkReq generation related

module mkSimGenWorkReqByOpCode#(
    PipeOut#(WorkReqOpCode) workReqOpCodePipeIn,
    Length minLength,
    Length maxLength,
    WorkReqSendFlag flag
)(Vector#(vSz, PipeOut#(WorkReq)));
    FIFOF#(WorkReq) workReqOutQ <- mkFIFOF;
    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IMM) immDtPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rkey2InvPipeOut <- mkGenericRandomPipeOut;
    let dmaLenPipeOut <- mkRandomLenPipeOut(minLength, maxLength);
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(workReqOutQ));

    rule genWorkReq;
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let dmaLen = dmaLenPipeOut.first;
        dmaLenPipeOut.deq;

        let wrOpCode = workReqOpCodePipeIn.first;
        workReqOpCodePipeIn.deq;

        let isAtomicWR = isAtomicWorkReq(wrOpCode);

        let comp = compPipeOut.first;
        compPipeOut.deq;

        let swap = swapPipeOut.first;
        swapPipeOut.deq;

        let immDt = immDtPipeOut.first;
        immDtPipeOut.deq;

        let rkey2Inv = rkey2InvPipeOut.first;
        rkey2InvPipeOut.deq;

        QPN sqpn = getDefaultQPN;
        QPN srqn = dontCareValue;
        QPN dqpn = getDefaultQPN;
        QKEY qkey = dontCareValue;
        let workReq = WorkReq {
            id       : wrID,
            opcode   : wrOpCode,
            flags    : enum2Flag(flag),
            raddr    : isAtomicWR ? 0 : dontCareValue,
            rkey     : dontCareValue,
            len      : isAtomicWR ? fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)) : dmaLen,
            laddr    : dontCareValue,
            lkey     : dontCareValue,
            sqpn     : sqpn,
            solicited: dontCareValue,
            comp     : workReqHasComp(wrOpCode) ? (tagged Valid comp) : (tagged Invalid),
            swap     : workReqHasSwap(wrOpCode) ? (tagged Valid swap) : (tagged Invalid),
            immDt    : workReqHasImmDt(wrOpCode) ? (tagged Valid immDt) : (tagged Invalid),
            rkey2Inv : workReqHasInv(wrOpCode) ? (tagged Valid rkey2Inv) : (tagged Invalid),
            srqn     : tagged Valid srqn,
            dqpn     : tagged Valid dqpn,
            qkey     : tagged Valid qkey
        };
        workReqOutQ.enq(workReq);
        // $display("time=%0t: generate random WR=", $time, fshow(workReq));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomWorkReqInRange#(
    Vector#(wrVecSz, WorkReqOpCode) workReqOpCodeVec,
    Length minLength,
    Length maxLength,
    WorkReqSendFlag flag
)(Vector#(vSz, PipeOut#(WorkReq)));
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    let resultPipeOutVec <- mkSimGenWorkReqByOpCode(
        workReqOpCodePipeOut, minLength, maxLength, flag
    );
    return resultPipeOutVec;
endmodule

module mkRandomWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    Vector#(8, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD,
        IBV_WR_SEND_WITH_INV
    );
    let wrFlags = IBV_SEND_SIGNALED;
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomSendOrWriteImmWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    Vector#(4, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV,
        IBV_WR_RDMA_WRITE_WITH_IMM
    );
    let wrFlags = IBV_SEND_SIGNALED;
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomSendWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    Vector#(3, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV
    );
    let wrFlags = IBV_SEND_SIGNALED;
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomSendOrWriteImmWorkReqWithNoAck#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    Vector#(4, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV,
        IBV_WR_RDMA_WRITE_WITH_IMM
    );
    let wrFlags = IBV_SEND_NO_FLAGS;
    let resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomReadWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    PipeOut#(WorkReqOpCode) readWorkReqOpCodePipeOut <-
        mkConstantPipeOut(IBV_WR_RDMA_READ);
    let wrFlags = IBV_SEND_NO_FLAGS;
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <- mkSimGenWorkReqByOpCode(
        readWorkReqOpCodePipeOut, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomReadOrAtomicWorkReq#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkReq)));
    Vector#(3, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD
    );
    let wrFlags = IBV_SEND_NO_FLAGS;
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <- mkRandomWorkReqInRange(
        workReqOpCodeVec, minLength, maxLength, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkGenIllegalAtomicWorkReq(PipeOut#(WorkReq));
    FIFOF#(WorkReq) workReqOutQ <- mkFIFOF;
    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR) addrPipeOut <- mkGenericRandomPipeOut;
    let atomicWorkReqOpCodePipeOut <- mkRandomAtomicWorkReqOpCode;

    rule genWorkReq;
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let addr = addrPipeOut.first;
        addrPipeOut.deq;

        ADDR unalignedAddr = truncate({ addr, 1'b1 });

        let wrOpCode = atomicWorkReqOpCodePipeOut.first;
        atomicWorkReqOpCodePipeOut.deq;

        Long comp = dontCareValue;
        Long swap = dontCareValue;
        QPN sqpn = getDefaultQPN;
        QPN dqpn = getDefaultQPN;
        QKEY qkey = dontCareValue;
        let workReq = WorkReq {
            id       : wrID,
            opcode   : wrOpCode,
            flags    : enum2Flag(IBV_SEND_NO_FLAGS),
            raddr    : unalignedAddr,
            rkey     : dontCareValue,
            len      : fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
            laddr    : dontCareValue,
            lkey     : dontCareValue,
            sqpn     : sqpn,
            solicited: dontCareValue,
            comp     : tagged Valid comp,
            swap     : tagged Valid swap,
            immDt    : tagged Invalid,
            rkey2Inv : tagged Invalid,
            srqn     : tagged Invalid,
            dqpn     : tagged Valid dqpn,
            qkey     : tagged Invalid
        };
        workReqOutQ.enq(workReq);
        // $display("time=%0t: generate illegal atomic WR=", $time, fshow(workReq));
    endrule

    return convertFifo2PipeOut(workReqOutQ);
endmodule

module mkGenNormalOrDupWorkReq#(
    Bool normalOrDupReq,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(Tuple2#(PipeOut#(Bool), PipeOut#(PendingWorkReq)));
    Reg#(Bool) normalOrDupReqReg <- mkReg(True);
    Reg#(PendingWorkReq) dupWorkReqReg <- mkRegU;

    PipeOut#(Tuple2#(Bool, PendingWorkReq)) normalOrDupWorkReqPipeOut = interface PipeOut;
        method Tuple2#(Bool, PendingWorkReq) first();
            return tuple2(
                normalOrDupReqReg,
                normalOrDupReqReg ?
                    pendingWorkReqPipeIn.first : dupWorkReqReg
            );
        endmethod

        method Action deq();
            if (normalOrDupReqReg) begin
                pendingWorkReqPipeIn.deq;
                dupWorkReqReg <= pendingWorkReqPipeIn.first;
                // $display(
                //     "time=%0t:", $time,
                //     " normal pendingWR=", fshow(pendingWorkReqPipeIn.first)
                // );
            end
            else begin
                // $display(
                //     "time=%0t:", $time,
                //     " duplicate pendingWR=", fshow(dupWorkReqReg)
                // );
            end

            if (!normalOrDupReq) begin
                normalOrDupReqReg <= !normalOrDupReqReg;
            end
        endmethod

        method Bool notEmpty();
            return normalOrDupReqReg ? pendingWorkReqPipeIn.notEmpty : True;
        endmethod
    endinterface;

    let resultPipeOut <- mkFork(identityFunc, normalOrDupWorkReqPipeOut);
    return resultPipeOut;
endmodule

module mkExistingPendingWorkReqPipeOut#(
    Controller cntrl,
    PipeOut#(WorkReq) workReqPipeIn
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    FIFOF#(PendingWorkReq) pendingWorkReqOutQ <- mkFIFOF;
    let pendingWorkReqPipeOut = convertFifo2PipeOut(pendingWorkReqOutQ);

    rule checkExpectedPSN if (cntrl.isRTR2RTS);
        immAssert(
            cntrl.contextRQ.getEPSN == cntrl.getNPSN,
            "ePSN == nPSN assertion @ mkExistingPendingWorkReqPipeOut",
            $format(
                "cntrl.contextRQ.getEPSN=%h should == cntrl.getNPSN=%h",
                cntrl.contextRQ.getEPSN, cntrl.getNPSN,
                " which is required by mkExistingPendingWorkReqPipeOut"
            )
        );
    endrule

    rule genExistingPendingWorkReq if (cntrl.isRTS);
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let startPktSeqNum = cntrl.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
            calcPktNumNextAndEndPSN(
                startPktSeqNum,
                wr.len,
                cntrl.getPMTU
            );

        cntrl.setNPSN(nextPktSeqNum);
        let isOnlyReqPkt = isOnlyPkt || isReadWorkReq(wr.opcode);

        let pendingWR = PendingWorkReq {
            wr: wr,
            startPSN: tagged Valid startPktSeqNum,
            endPSN: tagged Valid endPktSeqNum,
            pktNum: tagged Valid totalPktNum,
            isOnlyReqPkt: tagged Valid isOnlyReqPkt
        };
        pendingWorkReqOutQ.enq(pendingWR);

        // $display(
        //     "time=%0t: generates pendingWR=", $time, fshow(pendingWR)
        // );
    endrule

    Vector#(vSz, PipeOut#(PendingWorkReq)) resultPipeOutVec <-
        mkForkVector(pendingWorkReqPipeOut);
    return resultPipeOutVec;
endmodule

// Misc simulation modules

module mkSimQpAttrPipeOut#(
    PMTU pmtu, Bool setExpectedPsnAsNextPSN, Bool setZero2ExpectedPsnAndNextPSN
)(PipeOut#(AttrQP));
    PSN minPSN = 0;
    PSN maxPSN = maxBound;

    Randomize#(PSN)  randomEPSN <- mkConstrainedRandomizer(minPSN, maxPSN);
    Randomize#(PSN)  randomNPSN <- mkConstrainedRandomizer(minPSN, maxPSN);
    Randomize#(PKEY) randomPKEY <- mkGenericRandomizer;
    Randomize#(QKEY) randomQKEY <- mkGenericRandomizer;

    Reg#(Bool) randInitedReg <- mkReg(False);

    FIFOF#(AttrQP) qpAttrQ <- mkFIFOF;

    rule initRandomizer if (!randInitedReg);
        randomEPSN.cntrl.init;
        randomNPSN.cntrl.init;
        randomPKEY.cntrl.init;
        randomQKEY.cntrl.init;

        randInitedReg <= True;
    endrule

    rule genQpAttr if (randInitedReg);
        let epsn <- randomEPSN.next;
        let npsn <- randomNPSN.next;
        let pkey <- randomPKEY.next;
        let qkey <- randomQKEY.next;

        if (setExpectedPsnAsNextPSN) begin
            epsn = npsn;
        end

        if (setZero2ExpectedPsnAndNextPSN) begin
            epsn = 0;
            npsn = 0;
        end

        let qpAttr = AttrQP {
            qpState          : dontCareValue,
            curQpState       : dontCareValue,
            pmtu             : pmtu,
            qkey             : qkey,
            rqPSN            : epsn,
            sqPSN            : npsn,
            dqpn             : getDefaultQPN,
            qpAccessFlags    : enum2Flag(IBV_ACCESS_REMOTE_WRITE) | enum2Flag(IBV_ACCESS_REMOTE_READ) | enum2Flag(IBV_ACCESS_REMOTE_ATOMIC),
            cap              : QpCapacity {
                maxSendWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxRecvWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxSendSGE   : fromInteger(valueOf(MAX_SEND_SGE)),
                maxRecvSGE   : fromInteger(valueOf(MAX_RECV_SGE)),
                maxInlineData: fromInteger(valueOf(MAX_INLINE_DATA))
            },
            pkeyIndex        : pkey,
            sqDraining       : False,
            maxReadAtomic    : fromInteger(valueOf(MAX_QP_RD_ATOM)),
            maxDestReadAtomic: fromInteger(valueOf(MAX_QP_DST_RD_ATOM)),
            minRnrTimer      : 1, // minRnrTimer 1 - 0.01 milliseconds delay
            timeout          : 1, // maxTimeOut 0 - infinite, 1 - 8.192 usec (0.000008 sec)
            retryCnt         : fromInteger(valueOf(DEFAULT_RETRY_NUM)),
            rnrRetry         : fromInteger(valueOf(DEFAULT_RETRY_NUM))
        };
        qpAttrQ.enq(qpAttr);
    endrule

    return convertFifo2PipeOut(qpAttrQ);
endmodule

typedef enum {
    SIM_CNTRL_CREATE_QP,
    SIM_CNTRL_INIT_QP,
    SIM_CNTRL_SET_QP_RTR,
    SIM_CNTRL_SET_QP_RTS,
    SIM_CNTRL_CHECK_RESP,
    SIM_CNTRL_NO_OP
} SimCntrlState deriving(Bits, Eq);

module mkChange2CntrlStateRTS#(
    SrvPortQP cntrlSrvPort, TypeQP qpType, PMTU pmtu,
    Bool setExpectedPsnAsNextPSN, Bool setZero2ExpectedPsnAndNextPSN
)(Empty);
    let qpAttrPipeOut <- mkSimQpAttrPipeOut(
        pmtu, setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );
    Reg#(SimCntrlState) simCntrlStateReg <- mkReg(SIM_CNTRL_CREATE_QP);

    rule createQP if (simCntrlStateReg == SIM_CNTRL_CREATE_QP);
        let qpInitAttr = QpInitAttr {
            qpType  : qpType,
            sqSigAll: False
        };

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        cntrlSrvPort.request.put(qpCreateReq);
        simCntrlStateReg <= SIM_CNTRL_INIT_QP;
    endrule

    rule initQP if (simCntrlStateReg == SIM_CNTRL_INIT_QP);
        let qpCreateResp <- cntrlSrvPort.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkChange2CntrlStateRTS",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when create QP"
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;

        let qpInitReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrlSrvPort.request.put(qpInitReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTR;
    endrule

    rule setRTR if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTR);
        let qpInitResp <- cntrlSrvPort.response.get;

        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkChange2CntrlStateRTS",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;

        qpAttr.qpState = IBV_QPS_RTR;
        let qpModifyReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrlSrvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTS;
    endrule

    rule setRTS if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTS);
        let qpRtrResp <- cntrlSrvPort.response.get;

        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkChange2CntrlStateRTS",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttrPipeOut.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let qpModifyReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrlSrvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_CHECK_RESP;
    endrule

    rule checkRtsResp if (simCntrlStateReg == SIM_CNTRL_CHECK_RESP);
        let qpRtsResp <- cntrlSrvPort.response.get;

        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkChange2CntrlStateRTS",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        // $display(
        //     "time=%0t: qpRtsResp=", $time, fshow(qpRtsResp),
        //     " should be success, and qpRtsResp.qpn=%h",
        //     qpRtsResp.qpn
        // );
        simCntrlStateReg <= SIM_CNTRL_NO_OP;
    endrule
endmodule

module mkSimController#(
    TypeQP qpType, PMTU pmtu, Bool setExpectedPsnAsNextPSN
)(Controller);
    let cntrl <- mkController;
    let setZero2ExpectedPsnAndNextPSN = False;
    let setCntrl2RTS <- mkChange2CntrlStateRTS(
        cntrl.srvPort, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );
    return cntrl;
endmodule
/*
module mkSimController#(
    TypeQP qpType, PMTU pmtu, Bool setExpectedPsnAsNextPSN
)(Controller);
    let qpAttrPipeOut <- mkSimQpAttrPipeOut(pmtu, setExpectedPsnAsNextPSN);
    let cntrl <- mkController;

    Reg#(SimCntrlState) simCntrlStateReg <- mkReg(SIM_CNTRL_CREATE_QP);
    // Reg#(Bool) qpCreateDoneReg <- mkReg(False);
    // Reg#(Bool)   qpInitDoneReg <- mkReg(False);
    // Reg#(Bool) qpModifyDoneReg <- mkReg(False);

    // rule createQP if (!qpCreateDoneReg);
    rule createQP if (simCntrlStateReg == SIM_CNTRL_CREATE_QP);
        let qpInitAttr = QpInitAttr {
            qpType  : qpType,
            sqSigAll: False
        };

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        cntrl.srvPort.request.put(qpCreateReq);
        simCntrlStateReg <= SIM_CNTRL_INIT_QP;
        // qpCreateDoneReg <= True;
    endrule

    // rule initQP if (qpCreateDoneReg && !qpInitDoneReg);
    rule initQP if (simCntrlStateReg == SIM_CNTRL_INIT_QP);
        let qpCreateResp <- cntrl.srvPort.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkSimController",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when create QP"
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;

        let qpInitReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrl.srvPort.request.put(qpInitReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTR;
        // qpInitDoneReg <= True;
    endrule

    rule setRTR if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTR);
        let qpInitResp <- cntrl.srvPort.response.get;

        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkSimController",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;

        qpAttr.qpState = IBV_QPS_RTR;
        let qpModifyReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrl.srvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTS;
        // qpModifyDoneReg <= True;
    endrule

    // rule setRTS if (qpCreateDoneReg && qpInitDoneReg && !qpModifyDoneReg);
    rule setRTS if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTS);
        let qpRtrResp <- cntrl.srvPort.response.get;

        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkSimController",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttrPipeOut.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let qpModifyReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };

        cntrl.srvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_CHECK_RESP;
        // qpModifyDoneReg <= True;
    endrule

    // rule checkRtsResp if (qpCreateDoneReg && qpInitDoneReg && qpModifyDoneReg);
    rule checkRtsResp if (simCntrlStateReg == SIM_CNTRL_CHECK_RESP);
        let qpRtsResp <- cntrl.srvPort.response.get;

        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkSimController",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        // $display(
        //     "time=%0t: qpRtsResp=", $time, fshow(qpRtsResp),
        //     " should be success, and qpRtsResp.qpn=%h",
        //     $time, qpRtsResp.qpn
        // );
        simCntrlStateReg <= SIM_CNTRL_NO_OP;
    endrule

    return cntrl;
endmodule
*/
module mkSimPermCheckMR#(Bool mrCheckPassOrFail)(PermCheckMR);
    FIFOF#(PermCheckInfo) checkReqQ <- mkFIFOF;
    FIFOF#(Bool) checkRespQ <- mkFIFOF;

    rule check;
        checkReqQ.deq;
        checkRespQ.enq(mrCheckPassOrFail);
    endrule

    return toGPServer(checkReqQ, checkRespQ);
endmodule

module mkSimMetaData4SinigleQP#(TypeQP qpType, PMTU pmtu)(MetaDataQPs);
    // TODO: merge mkExistingPendingWorkReqPipeOut into here
    let setExpectedPsnAsNextPSN = True;
    let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);

    interface srvPort = cntrl.srvPort; // toGPServer(reqQ, respQ);

    method Bool isValidQP(QPN qpn) = qpn == getDefaultQPN;

    method Maybe#(HandlerPD) getPD(QPN qpn);
        return tagged Valid dontCareValue;
    endmethod
    method Controller getCntrlByQPN(QPN qpn) = cntrl;
    method Controller getCntrlByIndexQP(IndexQP qpIndex) = cntrl;

    method Action clear();
        noAction;
    endmethod

    method Bool notEmpty() = True;
    method Bool notFull() = True;
endmodule

module mkSimGenRecvReq(Vector#(vSz, PipeOut#(RecvReq)));
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;
    PipeOut#(WorkReqID) recvReqIdPipeOut <- mkGenericRandomPipeOut;

    rule genRR;
        let rrID = recvReqIdPipeOut.first;
        recvReqIdPipeOut.deq;
        let rr = RecvReq {
            id   : rrID,
            len  : dontCareValue,
            laddr: dontCareValue,
            lkey : dontCareValue,
            sqpn : getDefaultQPN
        };
        recvReqQ.enq(rr);
    endrule

    Vector#(vSz, PipeOut#(RecvReq)) resultPipeOutVec <-
        mkForkVector(convertFifo2PipeOut(recvReqQ));
    return resultPipeOutVec;
endmodule

module mkSimRetryHandleErr#(Bool retryLimitExcOrTimeOutErr)(RetryHandleSQ);
    FIFOF#(RetryReq)   retryReqQ <- mkFIFOF;
    FIFOF#(RetryResp) retryRespQ <- mkFIFOF;
    FIFOF#(TimeOutNotification) timeOutNotificationQ <- mkFIFOF;

    Reg#(Bool) timeOutErrNotifiedReg <- mkReg(False);

    rule genRetryErr;
        if (retryLimitExcOrTimeOutErr) begin
            let retryReq = retryReqQ.first;
            retryReqQ.deq;

            retryRespQ.enq(RETRY_HANDLER_RETRY_LIMIT_EXC);
        end
        else if (!timeOutErrNotifiedReg) begin
            timeOutNotificationQ.enq(RETRY_HANDLER_TIMEOUT_ERR);
            timeOutErrNotifiedReg <= True;
        end
    endrule

    method Bool hasRetryErr() = True;
    method Bool isRetryDone() = False;
    method Bool  isRetrying() = False;

    method Action resetRetryCntAndTimeOutBySQ(
        ResetRetryCntAndTimeOutReq resetReq
    ) = noAction;

    method ActionValue#(TimeOutNotification) notifyTimeOut2SQ();
        timeOutNotificationQ.deq;
        return timeOutNotificationQ.first;
    endmethod

    interface srvPort = toGPServer(retryReqQ, retryRespQ);
endmodule

module mkSimInputPktBuf4SingleQP#(
    Bool isRespPktPipeIn,
    DataStreamPipeOut rdmaPktPipeIn,
    MetaDataQPs qpMetaData
)(RdmaPktMetaDataAndPayloadPipeOut);
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaPktPipeIn
    );
    let inputRdmaPktBuf <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );
    let reqPktMetaDataAndPayloadPipeIn = inputRdmaPktBuf[0].reqPktPipeOut;
    let respPktMetaDataAndPayloadPipeIn = inputRdmaPktBuf[0].respPktPipeOut;
    let cnpPipeIn = inputRdmaPktBuf[0].cnpPipeOut;

    for (Integer idx = 1; idx < valueOf(MAX_QP); idx = idx + 1) begin
        let reqPktMetaDataPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            inputRdmaPktBuf[idx].reqPktPipeOut.pktMetaData,
            "inputRdmaPktBuf[" + integerToString(idx) +
            "].reqPktPipeOut.pktMetaData empty assertion @ mkSimInputPktBuf4SingleQP"
        ));
        let reqPktPayloadPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            inputRdmaPktBuf[idx].reqPktPipeOut.payload,
            "inputRdmaPktBuf[" + integerToString(idx) +
            "].reqPktPipeOut.payload empty assertion @ mkSimInputPktBuf4SingleQP"
        ));

        let respPktMetaDataPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            inputRdmaPktBuf[idx].respPktPipeOut.pktMetaData,
            "inputRdmaPktBuf[" + integerToString(idx) +
            "].respPktPipeOut.pktMetaData empty assertion @ mkSimInputPktBuf4SingleQP"
        ));
        let respPktPayloadPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            inputRdmaPktBuf[idx].respPktPipeOut.payload,
            "inputRdmaPktBuf[" + integerToString(idx) +
            "].respPktPipeOut.payload empty assertion @ mkSimInputPktBuf4SingleQP"
        ));

        let cnpPipeOutEmptyRule <- addRules(genEmptyPipeOutRule(
            inputRdmaPktBuf[idx].cnpPipeOut,
            "inputRdmaPktBuf[" + integerToString(idx) +
            "].cnpPipeOut empty assertion @ mkSimInputPktBuf4SingleQP"
        ));
    end

    rule checkEmpty;
        if (isRespPktPipeIn) begin
            immAssert(
                !reqPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty &&
                !reqPktMetaDataAndPayloadPipeIn.payload.notEmpty,
                "reqPktMetaDataAndPayloadPipeIn assertion @ mkSimInputPktBuf4SingleQP",
                $format(
                    "reqPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty=",
                    fshow(reqPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty),
                    " and reqPktMetaDataAndPayloadPipeIn.payload.notEmpty=",
                    fshow(reqPktMetaDataAndPayloadPipeIn.payload.notEmpty),
                    " should both be false"
                )
            );
        end
        else begin
            immAssert(
                !respPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty &&
                !respPktMetaDataAndPayloadPipeIn.payload.notEmpty,
                "respPktMetaDataAndPayloadPipeIn assertion @ mkSimInputPktBuf4SingleQP",
                $format(
                    "respPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty=",
                    fshow(respPktMetaDataAndPayloadPipeIn.pktMetaData.notEmpty),
                    " and respPktMetaDataAndPayloadPipeIn.payload.notEmpty=",
                    fshow(respPktMetaDataAndPayloadPipeIn.payload.notEmpty),
                    " should both be false"
                )
            );
        end

        immAssert(
            !cnpPipeIn.notEmpty,
            "cnpPipeIn empty assertion @ mkTestReceiveCNP",
            $format(
                "cnpPipeIn.notEmpty=",
                fshow(cnpPipeIn.notEmpty),
                " should be false"
            )
        );
    endrule

    return isRespPktPipeIn ? respPktMetaDataAndPayloadPipeIn : reqPktMetaDataAndPayloadPipeIn;
endmodule

// PipeOut related

function PipeOut#(anytype) muxPipeOutFunc(
    PipeOut#(Bool) selectPipeIn, PipeOut#(anytype) pipeIn1, PipeOut#(anytype) pipeIn2
);
    PipeOut#(anytype) resultPipeOut = interface PipeOut;
        method anytype first();
            return selectPipeIn.first ? pipeIn1.first : pipeIn2.first;
        endmethod

        method Action deq();
            let sel = selectPipeIn.first;
            selectPipeIn.deq;

            if (sel) begin
                pipeIn1.deq;
            end
            else begin
                pipeIn2.deq;
            end

            // $display("time=%0t: sel=", $time, fshow(sel));
        endmethod

        method Bool notEmpty();
            return selectPipeIn.first ? pipeIn1.notEmpty : pipeIn2.notEmpty;
        endmethod
    endinterface;

    return resultPipeOut;
endfunction

function Tuple2#(PipeOut#(anytype), PipeOut#(anytype)) deMuxPipeOutFunc(
    PipeOut#(Bool) selectPipeIn, PipeOut#(anytype) pipeIn
);
    PipeOut#(anytype) p1 = interface PipeOut;
        method anytype first() if (selectPipeIn.first);
            return pipeIn.first;
        endmethod
        method Action deq() if (selectPipeIn.first);
            pipeIn.deq;
            selectPipeIn.deq;
        endmethod
        method Bool notEmpty() if (selectPipeIn.first);
            return pipeIn.notEmpty;
        endmethod
    endinterface;

    PipeOut#(anytype) p2 = interface PipeOut;
        method anytype first() if (!selectPipeIn.first);
            return pipeIn.first;
        endmethod
        method Action deq() if (!selectPipeIn.first);
            pipeIn.deq;
            selectPipeIn.deq;
        endmethod
        method Bool notEmpty() if (!selectPipeIn.first);
            return pipeIn.notEmpty;
        endmethod
    endinterface;

    return tuple2(p1, p2);
endfunction

module mkBufferN#(
    Integer depth, PipeOut#(anytype) pipeIn
)(PipeOut#(anytype)) provisos(Bits#(anytype, tSz));
    let resultPipeOut <- mkBuffer_n(depth, pipeIn);
    return resultPipeOut;
endmodule

module mkFunc2Pipe#(
    function tb func(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut#(tb));
    let resultPipeOut <- mkFn_to_Pipe(func, pipeIn); // No delay
    return resultPipeOut;
endmodule

module mkActionValueFunc2Pipe#(
    function ActionValue#(tb) avfn(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut #(tb)) provisos(Bits #(ta, taSz), Bits #(tb, tbSz));
    // let resultPipeOut <- mkTap(avfn, pipeIn); // No delay
    let resultPipeOut <- mkAVFn_to_Pipe(avfn, pipeIn); // One cycle delay
    return resultPipeOut;
endmodule

module mkConstantPipeOut#(anytype constant)(PipeOut#(anytype));
    PipeOut#(anytype) resultPipeOut <- mkSource_from_constant(constant);
    return resultPipeOut;
endmodule

module mkPipeFilter#(
    function Bool filterFunc(anytype inputVal),
    PipeOut#(anytype) pipeIn
)(PipeOut#(anytype)) provisos(Bits #(anytype, anysize));
    FIFOF#(anytype) outQ <- mkFIFOF;

    rule filter;
        if (filterFunc(pipeIn.first)) begin
            outQ.enq (pipeIn.first);
        end
        pipeIn.deq;
    endrule

    return convertFifo2PipeOut(outQ);
endmodule

module mkDebugSink#(PipeOut#(anytype) pipeIn)(Empty) provisos(FShow#(anytype));
    rule drain;
        pipeIn.deq;
        $display("time=%0t: mkDebugSink drain ", $time, fshow(pipeIn.first));
    endrule
endmodule
