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
import QueuePair :: *;
import RetryHandleSQ :: *;
import Settings :: *;
import Utils :: *;

typedef 0 DEFAULT_QPN;
typedef 0 DEFAULT_QP_IDX;
typedef 10000 MAX_CMP_CNT;

function QPN getDefaultQPN();
    return fromInteger(valueOf(DEFAULT_QPN));
endfunction

function IndexQP getDefaultIndexQP();
    return fromInteger(valueOf(DEFAULT_QP_IDX));
endfunction

function Integer getMaxFragBufSize();
    return valueOf(PMTU_MAX_FRAG_NUM);
endfunction

interface CountDown;
    method Action decr();
    method int   _read();
endinterface

function Action normalExit();
    action
        $info("time=%0t: normal finished", $time);
        $finish(0);
    endaction
endfunction

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
            $info("time=%0t: normal finished after %0d cycles", $time, cycleNumReg);
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

// This function should be used in simulation only
function ByteEn addPadding2LastFragByteEn(ByteEn lastFragByteEn);
    let lastFragValidByteNum = calcByteEnBitNumInSim(lastFragByteEn);
    let padCnt = calcPadCnt(lastFragValidByteNum);
    let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
    let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
    return lastFragByteEnWithPadding;
endfunction
/*
// This module should be used in simulation only
module mkSegmentDataStreamByPmtu#(
    DataStreamPipeOut dataStreamPipeIn,
    PipeOut#(PMTU) pmtuPipeIn
)(DataStreamPipeOut);
    Reg#(PktFragNum) pktFragNumReg <- mkRegU;
    Reg#(PktFragNum) fragCntReg <- mkRegU;
    FIFOF#(DataStream) dataQ <- mkFIFOF;
    Reg#(Bool) setFirstReg <- mkReg(False);

    rule segment;
        let curData = dataStreamPipeIn.first;
        dataStreamPipeIn.deq;
        Bool isFragCntZero = isZero(fragCntReg);

        if (!setFirstReg && curData.isFirst) begin
            let pmtu = pmtuPipeIn.first;
            pmtuPipeIn.deq;
            let pktFragNum = calcFragNumByPMTU(pmtu);
            pktFragNumReg <= pktFragNum;
            fragCntReg <= pktFragNum - 2;
        end
        else if (setFirstReg) begin
            curData.isFirst = True;
            setFirstReg <= False;
            fragCntReg <= pktFragNumReg - 2;
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
*/
module mkDataStreamAddPadding#(
    DataStreamPipeOut dataStreamPipeIn
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

    let resultPipeOut <- mkFunc2Pipe(addPadding, dataStreamPipeIn);
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

    return toPipeOut(randomValQ);
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
    let resultPipeOutVec <- mkForkVector(toPipeOut(randomValQ));

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
    Vector#(1, PipeOut#(Length)) resultVec <- mkRandomValueInRangePipeOut(
        minLength, maxLength
    );
    return resultVec[0];
endmodule
/*
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

    return toPipeOut(lenQ);
endmodule
*/
module mkFixedLenHeaderMetaPipeOut#(
    PipeOut#(HeaderByteNum) headerLenPipeIn,
    Bool alwaysHasPayload
)(Vector#(vSz, PipeOut#(HeaderMetaData)));
    FIFOF#(HeaderMetaData) headerMetaDataQ <- mkFIFOF;
    Vector#(vSz, PipeOut#(HeaderMetaData)) resultPipeOutVec <-
        mkForkVector(toPipeOut(headerMetaDataQ));

    rule enq;
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragValidByeNum(headerLen);
        let headerMetaData = HeaderMetaData {
            headerLen           : headerLen,
            headerFragNum       : headerFragNum,
            lastFragValidByteNum: headerLastFragValidByteNum,
            // Use the last bit of HeaderLen to randomize hasPayload
            hasPayload          : alwaysHasPayload || unpack(headerLen[0]),
            isEmptyHeader       : False
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
            toPipeOut(headerLenQ),
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

        RDMA_READ_RESPONSE_FIRST           ,
        RDMA_READ_RESPONSE_MIDDLE          ,
        RDMA_READ_RESPONSE_LAST            ,
        RDMA_READ_RESPONSE_ONLY            : (wrOpCode == IBV_WR_RDMA_READ_RESP);

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
    let payloadLenPipeOut <- mkRandomLenPipeOut(minLength, maxLength);
    Vector#(vSz, PipeOut#(WorkReq)) resultPipeOutVec <-
        mkForkVector(toPipeOut(workReqOutQ));

    rule genWorkReq;
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

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
        QPN srqn = getDefaultQPN; // For XRC
        QPN dqpn = getDefaultQPN;
        QKEY qkey = dontCareValue;
        let workReq = WorkReq {
            id       : wrID,
            opcode   : wrOpCode,
            flags    : enum2Flag(flag),
            raddr    : isAtomicWR ? 0 : dontCareValue,
            rkey     : dontCareValue,
            len      : isAtomicWR ? fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)) : payloadLen,
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

    return toPipeOut(workReqOutQ);
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
                let pendingWR = pendingWorkReqPipeIn.first;
                pendingWorkReqPipeIn.deq;
                dupWorkReqReg <= pendingWR;

                immAssert(
                    isValid(pendingWR.pktNum),
                    "pendingWR.pktNum assertion @ mkGenNormalOrDupWorkReq",
                    $format(
                        "pendingWR.pktNum=", fshow(pendingWR.pktNum),
                        " should be valid"
                    )
                );
                // $display(
                //     "time=%0t:", $time,
                //     " normal pendingWR=", fshow(pendingWorkReqPipeIn.first)
                // );
            end
            // else begin
            //     $display(
            //         "time=%0t:", $time,
            //         " duplicate pendingWR=", fshow(dupWorkReqReg)
            //     );
            // end

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
/*
module mkGenNormalOrDupWorkReq2#(
    Bool normalOrDupReq,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(Tuple2#(PipeOut#(Tuple2#(Bool, PktNum)), PipeOut#(PendingWorkReq)));
    Reg#(Bool) normalOrDupReqReg <- mkReg(True);
    Reg#(PendingWorkReq) dupWorkReqReg <- mkRegU;

    PipeOut#(Tuple2#(Tuple2#(Bool, PktNum), PendingWorkReq)) normalOrDupWorkReqPipeOut = interface PipeOut;
        method Tuple2#(Tuple2#(Bool, PktNum), PendingWorkReq) first();
            let pendingWR = pendingWorkReqPipeIn.first;
            return tuple2(
                normalOrDupReqReg ?
                    tuple2(True, unwrapMaybe(pendingWR.pktNum)) :
                    tuple2(False, unwrapMaybe(dupWorkReqReg.pktNum)),
                normalOrDupReqReg ? pendingWR : dupWorkReqReg
            );
        endmethod

        method Action deq();
            if (normalOrDupReqReg) begin
                let pendingWR = pendingWorkReqPipeIn.first;
                pendingWorkReqPipeIn.deq;
                dupWorkReqReg <= pendingWR;

                immAssert(
                    isValid(pendingWR.pktNum),
                    "pendingWR.pktNum assertion @ mkGenNormalOrDupWorkReq",
                    $format(
                        "pendingWR.pktNum=", fshow(pendingWR.pktNum),
                        " should be valid"
                    )
                );
                // $display(
                //     "time=%0t:", $time,
                //     " normal pendingWR=", fshow(pendingWorkReqPipeIn.first)
                // );
            end
            // else begin
            //     $display(
            //         "time=%0t:", $time,
            //         " duplicate pendingWR=", fshow(dupWorkReqReg)
            //     );
            // end

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

// PktNum must be larger than zero
module mkExpandAggregatedPipeOut#(
    PipeOut#(Tuple2#(anytype, PktNum)) aggregatedPipeIn
)(PipeOut#(Tuple2#(anytype, PktNum)));
    Count#(PktNum) remainingCnt <- mkCount(0);

    PipeOut#(Tuple2#(anytype, PktNum)) expandedPipeOut = interface PipeOut;
        method Tuple2#(anytype, PktNum) first();
            let { inputVal, inputCnt } = aggregatedPipeIn.first;
            return isOne(inputCnt) ? aggregatedPipeIn.first : tuple2(inputVal, remainingCnt);
        endmethod

        method Action deq();
            let { inputVal, inputCnt } = aggregatedPipeIn.first;
            if (isOne(inputCnt) || isOne(remainingCnt)) begin
                aggregatedPipeIn.deq;
                remainingCnt <= 0;
            end
            else begin
                remainingCnt <= inputCnt - 1;
            end

            immAssert(
                !isZero(inputCnt),
                "inputCnt assertion @ mkGenNormalOrDupWorkReq",
                $format(
                    "inputCnt=", fshow(inputCnt), " should be valid"
                )
            );
        endmethod

        method Bool notEmpty() = aggregatedPipeIn.notEmpty;
    endinterface;

    return expandedPipeOut;
endmodule
*/
module mkExistingPendingWorkReqPipeOut#(
    CntrlQP cntrl,
    PipeOut#(WorkReq) workReqPipeIn
)(Vector#(vSz, PipeOut#(PendingWorkReq)));
    FIFOF#(PendingWorkReq) pendingWorkReqOutQ <- mkFIFOF;
    let pendingWorkReqPipeOut = toPipeOut(pendingWorkReqOutQ);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    rule checkExpectedPSN if (cntrlStatus.comm.isRTR2RTS);
        immAssert(
            cntrl.contextRQ.getEPSN == cntrl.contextSQ.getNPSN,
            "ePSN == nPSN assertion @ mkExistingPendingWorkReqPipeOut",
            $format(
                "cntrl.contextRQ.getEPSN=%h should == cntrl.contextSQ.getNPSN=%h",
                cntrl.contextRQ.getEPSN, cntrl.contextSQ.getNPSN,
                " which is required by mkExistingPendingWorkReqPipeOut"
            )
        );
    endrule

    rule genExistingPendingWorkReq if (cntrlStatus.comm.isRTS);
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let startPktSeqNum = cntrl.contextSQ.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } =
            calcPktNumNextAndEndPSN(
                startPktSeqNum,
                wr.len,
                cntrlStatus.comm.getPMTU
            );

        cntrl.contextSQ.setNPSN(nextPktSeqNum);
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

function PipeOut#(PendingWorkReq) genNewPendingWorkReqPipeOut(
    PipeOut#(WorkReq) workReqPipeIn
);
    return interface PipeOut#(PendingWorkReq);
        method PendingWorkReq first();
            let wr = workReqPipeIn.first;
            return PendingWorkReq {
                wr          : wr,
                startPSN    : tagged Invalid,
                endPSN      : tagged Invalid,
                pktNum      : tagged Invalid,
                isOnlyReqPkt: tagged Invalid
            };
        endmethod
        method Action deq() = workReqPipeIn.deq;
        method Bool notEmpty() = workReqPipeIn.notEmpty;
    endinterface;
endfunction

function PipeOut#(PendingWorkReq) genFixedPsnPendingWorkReqPipeOut(
    PipeOut#(WorkReq) workReqPipeIn
);
    return interface PipeOut#(PendingWorkReq);
        method PendingWorkReq first();
            let wr = workReqPipeIn.first;
            return PendingWorkReq {
                wr          : wr,
                startPSN    : tagged Valid 0,
                endPSN      : tagged Valid 0,
                pktNum      : tagged Valid 1,
                isOnlyReqPkt: tagged Valid True
            };
        endmethod
        method Action deq() = workReqPipeIn.deq;
        method Bool notEmpty() = workReqPipeIn.notEmpty;
    endinterface;
endfunction

// Misc simulation modules

module mkQpAttrPipeOut(PipeOut#(AttrQP));
    FIFOF#(AttrQP) qpAttrQ <- mkFIFOF;
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) dqpnCnt <- mkCount(0);

    rule genQpAttr if (dqpnCnt < fromInteger(valueOf(MAX_QP)));
        QPN dqpn = zeroExtendLSB(dqpnCnt);
        dqpnCnt.incr(1);

        let qpAttr = AttrQP {
            qpState          : dontCareValue,
            curQpState       : dontCareValue,
            pmtu             : IBV_MTU_1024,
            qkey             : fromInteger(valueOf(DEFAULT_QKEY)),
            rqPSN            : 0,
            sqPSN            : 0,
            dqpn             : dqpn,
            qpAccessFlags    : enum2Flag(IBV_ACCESS_REMOTE_WRITE) | enum2Flag(IBV_ACCESS_REMOTE_READ) | enum2Flag(IBV_ACCESS_REMOTE_ATOMIC),
            cap              : QpCapacity {
                maxSendWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxRecvWR    : fromInteger(valueOf(MAX_QP_WR)),
                maxSendSGE   : fromInteger(valueOf(MAX_SEND_SGE)),
                maxRecvSGE   : fromInteger(valueOf(MAX_RECV_SGE)),
                maxInlineData: fromInteger(valueOf(MAX_INLINE_DATA))
            },
            pkeyIndex        : fromInteger(valueOf(DEFAULT_PKEY)),
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

    return toPipeOut(qpAttrQ);
endmodule

// TODO: refactor mkQpAttrPipeOut and mkSimQpAttrPIpeOut
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

    return toPipeOut(qpAttrQ);
endmodule

typedef enum {
    SIM_CNTRL_CREATE_QP,
    SIM_CNTRL_INIT_QP,
    SIM_CNTRL_SET_QP_RTR,
    SIM_CNTRL_SET_QP_RTS,
    SIM_CNTRL_CHECK_RTS_RESP,
    SIM_CNTRL_DESTROY_QP,
    SIM_CNTRL_CHECK_DESTROY_RESP,
    SIM_CNTRL_WAIT_RESET
} SimCntrlState deriving(Bits, Eq);

module mkCntrlStateCycle#(
    SrvPortQP cntrlSrvPort,
    CntrlStatus cntrlStatus,
    QPN qpn,
    TypeQP qpType,
    PMTU pmtu,
    Bool setExpectedPsnAsNextPSN,
    Bool setZero2ExpectedPsnAndNextPSN,
    Bool qpDestroyWhenErr
)(Empty);
    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };
    let qpAttrPipeOut <- mkSimQpAttrPipeOut(
        pmtu, setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );
    Reg#(SimCntrlState) simCntrlStateReg <- mkReg(SIM_CNTRL_CREATE_QP);

    rule createQP if (simCntrlStateReg == SIM_CNTRL_CREATE_QP);
        immAssert(
            cntrlStatus.comm.isReset,
            "cntrlStatus state assertion @ mkCntrlStateCycle",
            $format(
                "cntrlStatus.comm.isReset=", fshow(cntrlStatus.comm.isReset),
                " should be true"
            )
        );

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : qpn,
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
            "qpCreateResp.successOrNot assertion @ mkCntrlStateCycle",
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
            qpn       : qpn,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };

        cntrlSrvPort.request.put(qpInitReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTR;
        // $display(
        //     "time=%0t: qpCreateResp=", $time, fshow(qpCreateResp),
        //     " should be success, and qpCreateResp.qpn=%h",
        //     qpCreateResp.qpn
        // );
    endrule

    rule setRTR if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTR);
        let qpInitResp <- cntrlSrvPort.response.get;

        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkCntrlStateCycle",
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
            qpn       : qpn,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };

        cntrlSrvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_SET_QP_RTS;
        // $display(
        //     "time=%0t: qpInitResp=", $time, fshow(qpInitResp),
        //     " should be success, and qpInitResp.qpn=%h",
        //     qpInitResp.qpn
        // );
    endrule

    rule setRTS if (simCntrlStateReg == SIM_CNTRL_SET_QP_RTS);
        let qpRtrResp <- cntrlSrvPort.response.get;

        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkCntrlStateCycle",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        // qpAttrPipeOut.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let qpModifyReq = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : qpn,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };

        cntrlSrvPort.request.put(qpModifyReq);
        simCntrlStateReg <= SIM_CNTRL_CHECK_RTS_RESP;
        // $display(
        //     "time=%0t: qpRtrResp=", $time, fshow(qpRtrResp),
        //     " should be success, and qpRtrResp.qpn=%h",
        //     qpRtrResp.qpn
        // );
    endrule

    rule checkRtsResp if (simCntrlStateReg == SIM_CNTRL_CHECK_RTS_RESP);
        let qpRtsResp <- cntrlSrvPort.response.get;

        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkCntrlStateCycle",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            cntrlStatus.comm.isRTS,
            "cntrlStatus.comm.isRTS assertion @ mkCntrlStateCycle",
            $format(
                "cntrlStatus.comm.isRTS=", fshow(cntrlStatus.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        if (qpDestroyWhenErr) begin
            simCntrlStateReg <= SIM_CNTRL_DESTROY_QP;
        end
        else begin
            simCntrlStateReg <= SIM_CNTRL_WAIT_RESET;
        end
        // $display(
        //     "time=%0t: qpRtsResp=", $time, fshow(qpRtsResp),
        //     " should be success, and qpRtsResp.qpn=%h",
        //     qpRtsResp.qpn
        // );
    endrule

    rule destroyQP if (
        simCntrlStateReg == SIM_CNTRL_DESTROY_QP &&
        cntrlStatus.comm.isERR
    );
        let qpAttr = qpAttrPipeOut.first;

        let deleteReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : qpInitAttr
        };
        cntrlSrvPort.request.put(deleteReqQP);
        simCntrlStateReg <= SIM_CNTRL_CHECK_DESTROY_RESP;
    endrule

    rule checkDestroyResp if (simCntrlStateReg == SIM_CNTRL_CHECK_DESTROY_RESP);
        let qpDestroyResp <- cntrlSrvPort.response.get;

        immAssert(
            qpDestroyResp.successOrNot,
            "qpDestroyResp.successOrNot assertion @ mkCntrlStateCycle",
            $format(
                "qpDestroyResp.successOrNot=", fshow(qpDestroyResp.successOrNot),
                " should be true when qpDestroyResp=", fshow(qpDestroyResp)
            )
        );

        immAssert(
            cntrlStatus.comm.isReset,
            "cntrlStatus.comm.isReset assertion @ mkCntrlStateCycle",
            $format(
                "cntrlStatus.comm.isReset=", fshow(cntrlStatus.comm.isReset),
                " should be true when qpDestroyResp=", fshow(qpDestroyResp)
            )
        );

        simCntrlStateReg <= SIM_CNTRL_CREATE_QP;
        // $display(
        //     "time=%0t: qpDestroyResp=", $time, fshow(qpDestroyResp),
        //     " should be success, and qpDestroyResp.qpn=%h",
        //     qpDestroyResp.qpn
        // );
    endrule
endmodule

module mkChangeCntrlState2RTS#(
    SrvPortQP cntrlSrvPort,
    CntrlStatus cntrlStatus,
    QPN qpn,
    TypeQP qpType,
    PMTU pmtu
)(Empty);
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let qpDestroyWhenErr = False;

    let setCntrl2RTS <- mkCntrlStateCycle(
        cntrlSrvPort,
        cntrlStatus,
        qpn,
        qpType,
        pmtu,
        setExpectedPsnAsNextPSN,
        setZero2ExpectedPsnAndNextPSN,
        qpDestroyWhenErr
    );
endmodule

module mkSimCntrl#(TypeQP qpType, PMTU pmtu)(CntrlQP);
    let cntrl <- mkCntrlQP;

    let setCntrl2RTS <- mkChangeCntrlState2RTS(
        cntrl.srvPort,
        cntrl.contextSQ.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu
    );

    // let setExpectedPsnAsNextPSN = True;
    // let setZero2ExpectedPsnAndNextPSN = False;
    // let qpDestroyWhenErr = False;
    // let setCntrl2RTS <- mkCntrlStateCycle(
    //     cntrl.srvPort,
    //     cntrl.contextSQ.statusSQ,
    //     getDefaultQPN,
    //     qpType,
    //     pmtu,
    //     setExpectedPsnAsNextPSN,
    //     setZero2ExpectedPsnAndNextPSN,
    //     qpDestroyWhenErr
    // );
    return cntrl;
endmodule

module mkSimCntrlStateCycle#(TypeQP qpType, PMTU pmtu)(CntrlQP);
    let cntrl <- mkCntrlQP;

    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = False;
    let qpDestroyWhenErr = True;

    let setCntrl2RTS <- mkCntrlStateCycle(
        cntrl.srvPort,
        cntrl.contextSQ.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu,
        setExpectedPsnAsNextPSN,
        setZero2ExpectedPsnAndNextPSN,
        qpDestroyWhenErr
    );
    return cntrl;
endmodule

module mkSimPermCheckSrv#(Bool mrCheckPassOrFail)(PermCheckSrv);
    FIFOF#(PermCheckReq) checkReqQ <- mkFIFOF;
    FIFOF#(Bool) checkRespQ <- mkFIFOF;

    rule check;
        checkReqQ.deq;
        checkRespQ.enq(mrCheckPassOrFail);
    endrule

    return toGPServer(checkReqQ, checkRespQ);
endmodule

module mkSimMetaData4SinigleQP#(TypeQP qpType, PMTU pmtu)(MetaDataQPs);
    let qp <- mkQP;
    let setCntrl2RTS <- mkChangeCntrlState2RTS(
        qp.srvPortQP,
        qp.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu
    );

    interface srvPort = qp.srvPortQP;

    method Bool isValidQP(QPN qpn) = qpn == getDefaultQPN;

    method Maybe#(HandlerPD) getPD(QPN qpn);
        return tagged Valid dontCareValue;
    endmethod
    method QueuePair getQueuePairByQPN(QPN qpn) = qp;
    method QueuePair getQueuePairByIndexQP(IndexQP qpIndex) = qp;

    method Bool notEmpty() = True;
    method Bool notFull()  = True;
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
        mkForkVector(toPipeOut(recvReqQ));
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
    let reqPktMetaDataAndPayloadPipeIn  = inputRdmaPktBuf[0].reqPktPipeOut;
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

module mkFunc2Pipe#(
    function tb func(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut#(tb));
    let resultPipeOut <- mkFn_to_Pipe(func, pipeIn); // No delay
    return resultPipeOut;
endmodule

module mkActionValueFunc2Pipe#(
    function ActionValue#(tb) avfn(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut #(tb)) provisos(Bits#(ta, taSz), Bits#(tb, tbSz));
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
)(PipeOut#(anytype)) provisos(Bits#(anytype, anysize));
    FIFOF#(anytype) outQ <- mkFIFOF;

    rule filter;
        if (filterFunc(pipeIn.first)) begin
            outQ.enq (pipeIn.first);
        end
        pipeIn.deq;
    endrule

    return toPipeOut(outQ);
endmodule

module mkVector2PipeOut#(
    Vector#(vSz, anytype) inVec, Bool isVecValid
)(PipeOut#(anytype)) provisos(
    FShow#(anytype),
    Bits#(anytype, anysize)
);
    Count#(Bit#(TLog#(vSz))) idxCnt <- mkCount(fromInteger(valueOf(vSz) - 1));

    method anytype first() = inVec[idxCnt];
    method Bool notEmpty() = isVecValid;
    method Action deq();
        if (isZero(idxCnt)) begin
            idxCnt <= fromInteger(valueOf(vSz) - 1);
        end
        else begin
            idxCnt.decr(1);
        end
        // $display(
        //     "time=%0t: mkVector2PipeOut deq", $time,
        //     ", vSz=%0d, idxCnt=%0d", valueOf(vSz), idxCnt,
        //     ", isVecValid=", fshow(isVecValid),
        //     ", first=", fshow(inVec[idxCnt])
        // );
    endmethod
endmodule

module mkDebugSink#(PipeOut#(anytype) pipeIn)(Empty) provisos(FShow#(anytype));
    rule drain;
        pipeIn.deq;
        $display(
            "time=%0t: mkDebugSink debug", $time,
            ", dequeue first=", fshow(pipeIn.first)
        );
    endrule
endmodule

module mkGetSink#(Get#(anytype) getIn)(Empty);
    rule drain;
        let result <- getIn.get;
    endrule
endmodule

module mkConnectionWhen#(
    Get#(anytype) getIn, Put#(anytype) putOut, Bool condition
)(Empty) provisos(Bits#(anytype, anysize));
    rule connect if (condition);
        let data <- getIn.get;
        putOut.put(data);
        // $display(
        //     "time=%0t: mkConnectionWhen connect", $time,
        //     ", condition=", fshow(condition)
        // );
    endrule
endmodule

module mkDebugConnection#(
    Get#(anytype) getIn, Put#(anytype) putOut
)(Empty) provisos(
    FShow#(anytype),
    Bits#(anytype, anysize),
    Bits#(DataStream, anysize)
);
    Reg#(BTH) bthReg <- mkRegU;

    rule connect;
        let data <- getIn.get;
        putOut.put(data);

        DataStream dataStream = unpack(pack(data));
        let bth = extractBTH(zeroExtendLSB(dataStream.data));
        if (dataStream.isFirst) begin
            bthReg <= bth;
            $display(
                "time=%0t: mkDebugConnection debug", $time,
                ", bth.dqpn=%h", bth.dqpn,
                ", bth=", fshow(bth),
                ", data=", fshow(data)
            );
        end
        else if (dataStream.isLast) begin
            $display(
                "time=%0t: mkDebugConnection debug", $time,
                ", bth.dqpn=%h", bthReg.dqpn,
                ", bth=", fshow(bthReg),
                ", data=", fshow(data)
            );
        end
        else begin
            $display(
                "time=%0t: mkDebugConnection debug", $time,
                ", bth.dqpn=%h", bthReg.dqpn,
                ", bth=", fshow(bthReg),
                ", data=", fshow(data)
            );
        end
    endrule
endmodule
