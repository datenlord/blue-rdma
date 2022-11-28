import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import Settings :: *;

function Bool isZero(Bit#(n) bits);
    Bool ret = unpack(|bits);
    return !ret;
endfunction

function Bool isAllOnes(Bit#(n) bits);
    Bool ret = unpack(&bits);
    return ret;
endfunction

function PipeOut#(a) convertFifo2PipeOut(FIFOF#(a) outputQ);
    return f_FIFOF_to_PipeOut(outputQ);
endfunction

function Bit#(n) zeroExtendLSB(Bit#(m) x) provisos(Add#(m, k, n));
    let reverseX = reverseBits(x);
    let extendReverseX = zeroExtend(reverseX);
    return reverseBits(extendReverseX);
endfunction

function Bit#(PMTU_MAX_WIDTH) getPmtuWidth(PMTU pmtu);
    return fromInteger(case (pmtu)
        MTU_256 :  8;
        MTU_512 :  9;
        MTU_1024: 10;
        MTU_2048: 11;
        MTU_4096: 12;
    endcase);
endfunction

function FragNum calcFragNumByPmtu(PMTU pmtu);
    // TODO: check DATA_BUS_BYTE_WIDTH must be power of 2
    let pmtuWidth = getPmtuWidth(pmtu);
    let busByteWidth = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    let shiftAmt = pmtuWidth - fromInteger(busByteWidth);
    return 1 << shiftAmt;
endfunction

function Tuple3#(FragNum, ByteEn, ByteEnBitNum) calcFragNumByLength(Length dlen);
    let shiftAmt = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    FragNum fragNum = truncate(dlen >> shiftAmt);
    BusByteWidthMask busByteWidthMask = maxBound;
    let lastFragSize = truncate(dlen) & busByteWidthMask;
    Bool lastFragEmpty = isZero(lastFragSize);
    if (!lastFragEmpty) begin
        fragNum = fragNum + 1;
    end

    ByteEnBitNum lastFragValidByteNum =
        lastFragEmpty ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : zeroExtend(lastFragSize);
    ByteEn lastFragByteEn = lastFragEmpty ? maxBound : ((1 << lastFragSize) - 1);
    return tuple3(fragNum, reverseBits(lastFragByteEn), lastFragValidByteNum);
endfunction

function Tuple3#(BusBitNum, ByteEnBitNum, BusBitNum) calcFragBitByteNum(
    ByteEnBitNum fragValidByteNum
);
    BusBitNum fragValidBitNum = zeroExtend(fragValidByteNum) << 3;
    ByteEnBitNum fragInvalidByteNum =
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - fragValidByteNum;
    BusBitNum fragInvalidBitNum = zeroExtend(fragInvalidByteNum) << 3;

    return tuple3(fragValidBitNum, fragInvalidByteNum, fragInvalidBitNum);
endfunction

/*
111
110
101
100
011
010
001
000
*/
function Bool psnInRangeExclusive(PSN psn, PSN psnStart, PSN psnEnd);
    let psnMSB = valueOf(PSN_WIDTH) - 1;

    let ret = False;
    let psnGtStart = psnStart < psn;
    let psnLtEnd = psn < psnEnd;
    if (psnStart[psnMSB] == psnEnd[psnMSB]) begin
        // PSN range no wrap around
        ret = psnGtStart && psnLtEnd;
    end
    else begin
        // PSN range has wrap around max PSN
        ret = (psnGtStart && psnStart[psnMSB] == psn[psnMSB]) ||
            (psnLtEnd && psn[psnMSB] == psnEnd[psnMSB]);
    end
    return ret;
endfunction

function Tuple3#(PktNum, PSN, PSN) calcNextAndEndPSN(PSN startPSN, Length len, PMTU pmtu);
    Bit#(PMTU_MAX_WIDTH) shiftAmt = pack(pmtu);
    let pmtuWidth = getPmtuWidth(pmtu);
    Bool zeroLength = isZero(len);
    PmtuMask pmtuMask = (1 << pmtuWidth) - 1;
    let lastPktSize = truncate(len) & pmtuMask; // len[pmtuWidth-1 : 0];
    Bool lastPktEmpty = isZero(lastPktSize);
    PktNum pktNum = truncate(len >> shiftAmt) + zeroExtend(pack(!lastPktEmpty));
    PSN nextPSN = startPSN + zeroExtend(pktNum);
    PSN endPSN = startPSN;
    // if (lastPktNotEmpty) begin
    //     pktNum = pktNum + 1;
    //     endPSN = nextPSN;
    //     nextPSN = nextPSN + 1;
    // end
    // else 
    if (!zeroLength) begin
        endPSN = nextPSN - 1;
    end
    else begin // zero length
        nextPSN = endPSN + 1;
    end
    return tuple3(pktNum, nextPSN, endPSN);
endfunction

// RDMA response handling

function Bool rdmaRespNeedDmaWrite(RdmaOpCode opcode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST, RDMA_READ_RESPONSE_MIDDLE, RDMA_READ_RESPONSE_LAST, RDMA_READ_RESPONSE_ONLY: True;
        ATOMIC_ACKNOWLEDGE: False; // TODO: support atomic response DMA write
        default: False;
    endcase;
endfunction

function Bool workReqMustExplicitAck(WorkReqOpCode opcode);
    return case (opcode)
        IBV_WR_RDMA_READ, IBV_WR_ATOMIC_CMP_AND_SWP, IBV_WR_ATOMIC_FETCH_AND_ADD: True;
        default: False;
    endcase;
endfunction

// TODO: support multiple WR flags
function Bool workReqNeedWorkComp(WorkReq wr);
    return wr.flags == IBV_SEND_SIGNALED || workReqMustExplicitAck(wr.opcode);
endfunction

function Bool isNormalRdmaResp(RdmaResp resp);
    // TODO: check if normal response or not
    return True;
endfunction

function Bool isRetryRdmaResp(RdmaResp resp);
    // TODO: check if retry response or not
    return False;
endfunction

function Bool isErrRdmaResp(RdmaResp resp);
    // TODO: check if fatal error response or not
    return False;
endfunction

module mkSegmentDataStreamByPmtu#(
    PipeOut#(DataStream) pipeInput, PMTU pmtu
)(PipeOut#(DataStream));
    FragNum pmtuFragNum = calcFragNumByPmtu(pmtu);
    Reg#(FragNum) fragCntReg <- mkRegU;
    FIFOF#(DataStream) dataQ <- mkFIFOF;
    Reg#(Bool) setFirstReg <- mkReg(False);
    Bool isFragCntZero = isZero(fragCntReg);

    rule enq;
        let curData = pipeInput.first;
        pipeInput.deq;

        if (setFirstReg) begin
            curData.isFirst = True;
            setFirstReg <= False;
        end

        if (curData.isFirst) begin
            fragCntReg <= pmtuFragNum - 2;
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

// Constant 2 PipeOut
module mkConstantPipeOut#(a x)(PipeOut #(a));
    PipeOut#(a) ret <- mkSource_from_constant(x);
    return ret;
endmodule

// DmaReadResp 2 PipeOut

module mkPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(PipeOut#(DmaReadResp));
    PipeOut#(DmaReadResp) ret <- mkSource_from_fav(resp.get);
    return ret;
endmodule

module mkDataStreamFromDmaReadResp#(PipeOut#(DmaReadResp) respPipeOut)(PipeOut#(DataStream));
    function DataStream getDmaReadRespData(DmaReadResp dmaReadResp) = dmaReadResp.data;
    PipeOut#(DataStream) ret <- mkFn_to_Pipe(getDmaReadRespData, respPipeOut);
    return ret;
endmodule

module mkDataStreamPipeOutFromDmaReadResp#(Get#(DmaReadResp) resp)(PipeOut#(DataStream));
    PipeOut#(DmaReadResp) dmaReadRespPipeOut <- mkPipeOutFromDmaReadResp(resp);
    PipeOut#(DataStream) ret <- mkDataStreamFromDmaReadResp(dmaReadRespPipeOut);

    // rule display;
    //     $display(
    //         "Before segment: time=%0d, isFirst=%b, isLast=%b, byteEn=%h",
    //         $time, ret.first.isFirst, ret.first.isLast, ret.first.byteEn
    //     );
    // endrule

    return ret;
endmodule
