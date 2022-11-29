import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import Settings :: *;

function Bool isZero(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    Bool ret = unpack(|bits);
    return !ret;
endfunction

function Bool isLessOrEqOne(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    Bool ret = isZero(bits >> 1);
    // Bool ret = isZero(bits >> 1) && unpack(bits[0]);
    return ret;
endfunction

function Bool isAllOnes(Bit#(nSz) bits);
    Bool ret = unpack(&bits);
    return ret;
endfunction

function Bool isLargerThanOne(Bit#(tSz) bits) provisos(Add#(1, kSz, tSz));
    return !isZero(bits >> 1);
endfunction

function Bit#(nSz) zeroExtendLSB(Bit#(mSz) bits) provisos(Add#(mSz, kSz, nSz));
    return { bits, 0 };
endfunction

// ByteEn related

function ByteEn genByteEn(ByteEnBitNum fragValidByteNum);
    return reverseBits((1 << fragValidByteNum) - 1);
endfunction

function ByteEnBitNum calcLastFragValidByteNum(Bit#(nSz) len)
provisos(Add#(DATA_BUS_BYTE_NUM_WIDTH, kSz, nSz), Add#(1, jSz, nSz));
    BusByteWidthMask busByteWidthMask = maxBound;
    ByteEnBitNum lastFragValidByteNum = zeroExtend(truncate(len) & busByteWidthMask);

    if (isZero(lastFragValidByteNum) && !isZero(len)) begin
        lastFragValidByteNum = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
    end
    return lastFragValidByteNum;
endfunction

function Tuple3#(BusBitNum, ByteEnBitNum, BusBitNum) calcFragBitNumAndByteNum(
    ByteEnBitNum fragValidByteNum
);
    BusBitNum fragValidBitNum = zeroExtend(fragValidByteNum) << 3;
    ByteEnBitNum fragInvalidByteNum =
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - fragValidByteNum;
    BusBitNum fragInvalidBitNum = zeroExtend(fragInvalidByteNum) << 3;

    return tuple3(fragValidBitNum, fragInvalidByteNum, fragInvalidBitNum);
endfunction

// TODO: check timing of the for loop
// TODO: refactor the for loop using case statement
function Maybe#(ByteEnBitNum) calcFragByteNumFromByteEn(ByteEn fragByteEn);
    let rightAlignedByteEn = reverseBits(fragByteEn);
    Maybe#(ByteEnBitNum) byteEnBitNum = tagged Invalid;
    let step = valueOf(FRAG_MIN_VALID_BYTE_NUM);
    // Bool matched = False;
    for (
        Integer idx = 0;
        idx <= valueOf(DATA_BUS_BYTE_WIDTH);
        idx = idx + step
    ) begin
        if (rightAlignedByteEn == (fromInteger(1) << idx) - 1) begin
            byteEnBitNum = tagged Valid fromInteger(idx);
            // matched = True;
        end
    end
    // $display("matched=%b, rightAlignedByteEn=%h", matched, rightAlignedByteEn);
    return byteEnBitNum;
endfunction

// PMTU related

function Integer getPmtuLogValue(PMTU pmtu);
    return case (pmtu)
        IBV_MTU_256 :  8; // log2(256)
        IBV_MTU_512 :  9; // log2(512)
        IBV_MTU_1024: 10; // log2(1024)
        IBV_MTU_2048: 11; // log2(2048)
        IBV_MTU_4096: 12; // log2(4096)
    endcase;
endfunction

// function PmtuValueWidth getPmtuWidth(PMTU pmtu);
//     return fromInteger(getPmtuLogValue(pmtu));
// endfunction

function PktLen calcPmtuLen(PMTU pmtu);
    return fromInteger(case (pmtu)
        IBV_MTU_256 :  256;
        IBV_MTU_512 :  512;
        IBV_MTU_1024: 1024;
        IBV_MTU_2048: 2048;
        IBV_MTU_4096: 4096;
    endcase);
endfunction

// function Bool lenEqPMTU(Bit#(nSz) len, PMTU pmtu) provisos(Add#(TLog#(MAX_PMTU), kSz, nSz));
//     let tmpPktLen = len;
//     tmpPktLen[getPmtuLogValue(pmtu)-1] = 0;
//     return isZero(tmpPktLen);
// endfunction

function Bool pktLenEqPMTU(PktLen pktLen, PMTU pmtu);
    let tmpPktLen = pktLen;
    tmpPktLen[getPmtuLogValue(pmtu)-1] = 0;
    return isZero(tmpPktLen);
endfunction

function PmtuFragNum calcFragNumByPmtu(PMTU pmtu);
    // TODO: check DATA_BUS_BYTE_WIDTH must be power of 2
    let busByteWidth = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    let pmtuWidth = getPmtuLogValue(pmtu);
    let shiftAmt = pmtuWidth - busByteWidth;
    return 1 << shiftAmt;
endfunction

// Header related

function HeaderByteEn genHeaderByteEn(HeaderByteNum headerLen);
    return reverseBits((1 << headerLen) - 1);
endfunction

function HeaderMetaData genHeaderMetaData(
    HeaderByteNum headerLen,
    Bool hasPayload
);
    let { headerFragNum, lastFragValidByteNum } =
        calcHeaderFragNumAndLastFragValidByeNum(headerLen);
    let headerMetaData = HeaderMetaData {
        headerLen: headerLen,
        headerFragNum: headerFragNum,
        lastFragValidByteNum: lastFragValidByteNum,
        hasPayload: hasPayload
    };
    return headerMetaData;
endfunction

function RdmaHeader genRdmaHeader(
    HeaderData headerData,
    HeaderByteNum headerLen,
    Bool hasPayload
);
    let headerByteEn = genHeaderByteEn(headerLen);
    let headerMetaData = genHeaderMetaData(headerLen, hasPayload);
    return RdmaHeader {
        headerData: headerData,
        headerByteEn: headerByteEn,
        headerMetaData: headerMetaData
    };
endfunction

function Tuple2#(HeaderFragNum, ByteEnBitNum) calcHeaderFragNumAndLastFragValidByeNum(
    HeaderByteNum headerLen
);
    let headerLastFragValidByteNum = calcLastFragValidByteNum(headerLen);
    BusByteWidthMask busByteWidthMask = maxBound;
    let headerLastFragByteEnBitNum = truncate(headerLen) & busByteWidthMask;
    HeaderFragNum headerFragNum =
        truncate(headerLen >> valueOf(DATA_BUS_BYTE_NUM_WIDTH)) +
        zeroExtend(pack(!(isZero(headerLastFragByteEnBitNum))));
    return tuple2(headerFragNum, headerLastFragValidByteNum);
endfunction

function Tuple2#(HeaderByteNum, HeaderBitNum) calcHeaderInvalidFragByteAndBitNum(
    HeaderFragNum headerValidFragNum
);
    HeaderFragNum headerInvalidFragNum =
        fromInteger(valueOf(HEADER_MAX_FRAG_NUM)) - headerValidFragNum;
    HeaderByteNum headerInvalidFragByteNum =
        zeroExtend(headerInvalidFragNum) << valueOf(DATA_BUS_BYTE_NUM_WIDTH);
    HeaderBitNum headerInvalidFragBitNum =
        zeroExtend(headerInvalidFragNum) << valueOf(DATA_BUS_BIT_NUM_WIDTH);
    return tuple2(headerInvalidFragByteNum, headerInvalidFragBitNum);
endfunction

// BTH related

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

function PSN psnDiff(PSN psnA, PSN psnB);
    return truncate({ 1'b1, psnA } - { 1'b0, psnB });
endfunction

function ADDR addrAddPsnMultiplyPMTU(ADDR addr, PSN psn, PMTU pmtu);
    return case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            { (addr[valueOf(ADDR_WIDTH)-1 : 8] + zeroExtend(psn)), addr[7 : 0] };
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            { (addr[valueOf(ADDR_WIDTH)-1 : 9] + zeroExtend(psn)), addr[8 : 0] };
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            { (addr[valueOf(ADDR_WIDTH)-1 : 10] + zeroExtend(psn)), addr[9 : 0] };
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            { (addr[valueOf(ADDR_WIDTH)-1 : 11] + zeroExtend(psn)), addr[10 : 0] };
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            { (addr[valueOf(ADDR_WIDTH)-1 : 12] + zeroExtend(psn)), addr[11 : 0] };
        end
    endcase;
endfunction

function Length lenSubtractPsnMultiplyPMTU(Length len, PSN psn, PMTU pmtu);
    return case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            { (len[valueOf(RDMA_MAX_LEN_WIDTH)-1 : 8] - psn), len[7 : 0] };
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            { (len[valueOf(RDMA_MAX_LEN_WIDTH)-1 : 9] - truncate(psn)), len[8 : 0] };
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            { (len[valueOf(RDMA_MAX_LEN_WIDTH)-1 : 10] - truncate(psn)), len[9 : 0] };
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            { (len[valueOf(RDMA_MAX_LEN_WIDTH)-1 : 11] - truncate(psn)), len[10 : 0] };
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            { (len[valueOf(RDMA_MAX_LEN_WIDTH)-1 : 12] - truncate(psn)), len[11 : 0] };
        end
    endcase;
endfunction

function Maybe#(TransType) qpType2TransType(QpType qpt);
    return case (qpt)
        IBV_QPT_RC      : tagged Valid TRANS_TYPE_RC;
        IBV_QPT_UD      : tagged Valid TRANS_TYPE_UD;
        IBV_QPT_XRC_RECV,
        IBV_QPT_XRC_SEND: tagged Valid TRANS_TYPE_XRC;
        default         : tagged Invalid;
    endcase;
endfunction

function PAD calcPadCnt(Length len);
    PadMask padMask = maxBound;
    PAD tmpCnt = truncate(len) & padMask;
    PAD padCnt = (1 << valueOf(PAD_WIDTH)) - tmpCnt;
    return padCnt;
endfunction

function Tuple2#(TransType, RdmaOpCode) extractTranTypeAndRdmaOpCode(
    Bit#(nSz) inputData
);
    TransType transType = unpack(inputData[
        valueOf(nSz)-1 :
        valueOf(nSz) - valueOf(TRANS_TYPE_WIDTH)
    ]);
    RdmaOpCode rdmaOpCode = unpack(inputData[
        valueOf(nSz) - valueOf(TRANS_TYPE_WIDTH) - 1 :
        valueOf(nSz) - valueOf(TRANS_TYPE_WIDTH) - valueOf(RDMA_OPCODE_WIDTH)
    ]);

    return tuple2(transType, rdmaOpCode);
endfunction

function BTH extractBTH(HeaderData headerData);
    let bth = unpack(headerData[
        valueOf(HEADER_MAX_DATA_WIDTH)-1 :
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH)
    ]);
    return bth;
endfunction

function BTH extractBTH2(DATA fragData);
    let bth = unpack(fragData[
        valueOf(DATA_BUS_WIDTH)-1 :
        valueOf(DATA_BUS_WIDTH) - valueOf(BTH_WIDTH)
    ]);
    return bth;
endfunction

function AETH extractAETH(HeaderData headerData);
    let aeth = unpack(headerData[
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(AETH_WIDTH)
    ]);
    return aeth;
endfunction

function AtomicAckEth extractAtomicAckEth(HeaderData headerData);
    let atomicAckEth = unpack(headerData[
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(AETH_WIDTH) -1 :
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(AETH_WIDTH) - valueOf(ATOMIC_ACK_ETH_WIDTH)
    ]);
    return atomicAckEth;
endfunction

function XRCETH extractXRCETH(HeaderData headerData);
    let xrcEth = unpack(headerData[
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
        valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH)
    ]);
    return xrcEth;
endfunction

function RETH extractRETH(HeaderData headerData, TransType transType);
    let reth = case (transType)
        TRANS_TYPE_XRC: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) - valueOf(RETH_WIDTH)
        ]);
        default: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(RETH_WIDTH)
        ]);
    endcase;
    return reth;
endfunction

function AtomicEth extractAtomicEth(HeaderData headerData, TransType transType);
    let atomicEth = case (transType)
        TRANS_TYPE_XRC: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) - valueOf(ATOMIC_ETH_WIDTH)
        ]);
        default: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(ATOMIC_ETH_WIDTH)
        ]);
    endcase;
    return atomicEth;
endfunction

function ImmDt extractImmDt(HeaderData headerData, TransType transType);
    let immDt = case (transType)
        TRANS_TYPE_XRC: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) - valueOf(IMM_DT_WIDTH)
        ]);
        default: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(IMM_DT_WIDTH)
        ]);
    endcase;
    return immDt;
endfunction

function IETH extractIETH(HeaderData headerData, TransType transType);
    let ieth = case (transType)
        TRANS_TYPE_XRC: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(XRCETH_WIDTH) - valueOf(IETH_WIDTH)
        ]);
        default: unpack(headerData[
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) -1 :
            valueOf(HEADER_MAX_DATA_WIDTH) - valueOf(BTH_WIDTH) - valueOf(IETH_WIDTH)
        ]);
    endcase;
    return ieth;
endfunction

function Bool isFirstRdmaOpCode(RdmaOpCode opcode);
    return case (opcode)
        SEND_FIRST              ,
        RDMA_WRITE_FIRST        ,
        RDMA_READ_RESPONSE_FIRST: True;

        default                 : False;
    endcase;
endfunction

function Bool isMiddleRdmaOpCode(RdmaOpCode opcode);
    return case (opcode)
        SEND_MIDDLE              ,
        RDMA_WRITE_MIDDLE        ,
        RDMA_READ_RESPONSE_MIDDLE: True;

        default                  : False;
    endcase;
endfunction

function Bool isLastRdmaOpCode(RdmaOpCode opcode);
    return case (opcode)
        SEND_LAST                     ,
        SEND_LAST_WITH_IMMEDIATE      ,
        SEND_LAST_WITH_INVALIDATE     ,

        RDMA_WRITE_LAST               ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE,

        RDMA_READ_RESPONSE_LAST       : True;

        default                       : False;
    endcase;
endfunction

function Bool isOnlyRdmaOpCode(RdmaOpCode opcode);
    return case (opcode)
        SEND_ONLY                     ,
        SEND_ONLY_WITH_IMMEDIATE      ,
        SEND_ONLY_WITH_INVALIDATE     ,

        RDMA_WRITE_ONLY               ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE,

        RDMA_READ_REQUEST             ,
        COMPARE_SWAP                  ,
        FETCH_ADD                     ,

        RDMA_READ_RESPONSE_ONLY       ,

        ACKNOWLEDGE                   ,
        ATOMIC_ACKNOWLEDGE            : True;

        default                       : False;
    endcase;
endfunction

function Bool isFirstOrOnlyRdmaOpCode(RdmaOpCode opcode);
    return isFirstRdmaOpCode(opcode) || isOnlyRdmaOpCode(opcode);
endfunction

function Bool isFirstOrMiddleRdmaOpCode(RdmaOpCode opcode);
    return isFirstRdmaOpCode(opcode) || isMiddleRdmaOpCode(opcode);
endfunction

function Bool isLastOrOnlyRdmaOpCode(RdmaOpCode opcode);
    return isLastRdmaOpCode(opcode) || isOnlyRdmaOpCode(opcode);
endfunction

function Bool isMiddleOrLastRdmaOpCode(RdmaOpCode opcode);
    return isLastRdmaOpCode(opcode) || isOnlyRdmaOpCode(opcode);
endfunction

function Bool isRdmaRespOpCode(RdmaOpCode opcode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  ,
        ACKNOWLEDGE              ,
        ATOMIC_ACKNOWLEDGE       : True;
        default                  : False;
    endcase;
endfunction

function Bool rdmaRespHasAETH(RdmaOpCode opcode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  ,
        ACKNOWLEDGE              ,
        ATOMIC_ACKNOWLEDGE       : True;
        default                  : False;
    endcase;
endfunction

function Bool rdmaRespHasAtomicAckEth(RdmaOpCode opcode);
    return opcode == ATOMIC_ACKNOWLEDGE;
endfunction

function Bool rdmaRespNeedDmaWrite(RdmaOpCode opcode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  ,
        ATOMIC_ACKNOWLEDGE       : True;
        default                  : False;
    endcase;
endfunction

function Bool rdmaReqHasRETH(RdmaOpCode opcode);
    return case (opcode)
        RDMA_WRITE_FIRST              ,
        RDMA_WRITE_ONLY               ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE,
        RDMA_READ_REQUEST             : True;
        default                       : False;
    endcase;
endfunction

function Bool rdmaReqHasImmDt(RdmaOpCode opcode);
    return case (opcode)
        SEND_LAST_WITH_IMMEDIATE      ,
        SEND_ONLY_WITH_IMMEDIATE      ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE: True;
        default                       : False;
    endcase;
endfunction

function Bool rdmaReqHasIETH(RdmaOpCode opcode);
    return case (opcode)
        SEND_LAST_WITH_INVALIDATE,
        SEND_ONLY_WITH_INVALIDATE: True;
        default                  : False;
    endcase;
endfunction

function RdmaRespType getRdmaRespType(RdmaOpCode opcode, AETH aeth);
    case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  ,
        ATOMIC_ACKNOWLEDGE       : return RDMA_RESP_NORMAL;

        ACKNOWLEDGE: case (aeth.code)
            AETH_CODE_ACK: return RDMA_RESP_NORMAL;
            AETH_CODE_RNR: return RDMA_RESP_RETRY;
            AETH_CODE_NAK: return case (aeth.value)
                zeroExtend(pack(AETH_NAK_SEQ_ERR)): RDMA_RESP_RETRY;
                zeroExtend(pack(AETH_NAK_INV_REQ)),
                zeroExtend(pack(AETH_NAK_RMT_ACC)),
                zeroExtend(pack(AETH_NAK_RMT_OP)) ,
                zeroExtend(pack(AETH_NAK_INV_RD)) : RDMA_RESP_ERROR;
                default: RDMA_RESP_UNKNOWN;
            endcase;
            // AETH_CODE_RSVD
            default: return RDMA_RESP_UNKNOWN;
        endcase
        default: return RDMA_RESP_UNKNOWN;
    endcase
endfunction

function RetryReason getRetryReasonFromAETH(AETH aeth);
    return case (aeth.code)
        AETH_CODE_RNR: RETRY_REASON_RNR;
        AETH_CODE_NAK: (
            (aeth.value == zeroExtend(pack(AETH_NAK_SEQ_ERR))) ?
                RETRY_REASON_SEQ_ERR : RETRY_REASON_NOT_RETRY
        );
        default: RETRY_REASON_NOT_RETRY;
    endcase;
endfunction

// function Maybe#(WorkCompStatus) getErrWorkCompStatusFromRetryReason(RetryReason rr);
//     return case (rr)
//         RETRY_REASON_RNR    : tagged Valid IBV_WC_RNR_RETRY_EXC_ERR;
//         RETRY_REASON_SEQ_ERR: tagged Valid IBV_WC_RETRY_EXC_ERR;
//         default             : tagged Invalid;
//     endcase;
// endfunction

function Bool rdmaNormalRespOpCodeSeqCheck(
    RdmaOpCode preOpCode, RdmaOpCode curOpCode
);
    return case (preOpCode)
        RDMA_READ_RESPONSE_FIRST : (curOpCode == RDMA_READ_RESPONSE_MIDDLE);
        RDMA_READ_RESPONSE_MIDDLE: (
            curOpCode == RDMA_READ_RESPONSE_MIDDLE ||
            curOpCode == RDMA_READ_RESPONSE_LAST
        );
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : True;
        default                  : True;
    endcase;
endfunction

function Bool rdmaRespMatchWorkReq(RdmaOpCode opcode, WorkReqOpCode wrOpCode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : (wrOpCode == IBV_WR_RDMA_READ);
        ATOMIC_ACKNOWLEDGE       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP || wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);
        ACKNOWLEDGE              : True;
        default                  : False;
    endcase;
endfunction

// function Bool isNormalRdmaResp(RdmaOpCode opcode, AETH aeth);
//     // TODO: check if normal response or not
//     return True;
// endfunction

// function Bool isRetryRdmaResp(RdmaOpCode opcode, AETH aeth);
//     // TODO: check if retry response or not
//     return False;
// endfunction

// function Bool isErrorRdmaResp(RdmaOpCode opcode, AETH aeth);
//     // TODO: check if fatal error response or not
//     return False;
// endfunction

// WorkReq related

function Tuple2#(Bool, PktNum) calcPktNumByLength(Length len, PMTU pmtu);
    let zeroLength = isZero(len);
    let pmtuValueWidth = getPmtuLogValue(pmtu);
    PmtuMask pmtuMask = (1 << pmtuValueWidth) - 1;
    let lastPktSize = truncate(len) & pmtuMask;
    // let lastPktSize = len[pmtuValueWidth-1 : 0];
    let lastPktEmpty = isZero(lastPktSize);
    // TODO: check zero pktNum will bring bugs or not
    PktNum pktNum = truncate(len >> pmtuValueWidth);
    if (!lastPktEmpty) begin
        pktNum = pktNum + 1;
    end
    // In case zero length, it is also only packet
    Bool isOnlyPkt = isLessOrEqOne(pktNum);
    return tuple2(isOnlyPkt, pktNum);
endfunction

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

function Bool workReqHasAckReq(WorkReq wr);
    return wr.flags == IBV_SEND_SIGNALED;
endfunction

function Bool workReqRequireAck(WorkReq wr);
    return workReqHasAckReq(wr) || isReadOrAtomicWorkReq(wr.opcode);
endfunction

function Bool workReqNeedDmaRead(WorkReq wr);
    return case (wr.opcode)
        IBV_WR_RDMA_WRITE         ,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND               ,
        IBV_WR_SEND_WITH_IMM      ,
        IBV_WR_SEND_WITH_INV      : !isZero(wr.len);
        default                   : False;
    endcase;
endfunction

// function Bool workReqNeedDmaWrite(WorkReq wr);
//     return case (wr.opcode)
//         IBV_WR_RDMA_READ           : !isZero(wr.len);
//         IBV_WR_ATOMIC_CMP_AND_SWP  ,
//         IBV_WR_ATOMIC_FETCH_AND_ADD: True;
//         default                    : False;
//     endcase;
// endfunction

function Bool workReqHasPayload(WorkReq wr);
    return !(isZero(wr.len) || isReadOrAtomicWorkReq(wr.opcode));
endfunction

// TODO: support multiple WR flags
function Bool workReqNeedWorkComp(WorkReq wr);
    return wr.flags == IBV_SEND_SIGNALED || isReadOrAtomicWorkReq(wr.opcode);
endfunction

function Bool workReqHasComp(WorkReqOpCode opcode);
    return opcode == IBV_WR_ATOMIC_CMP_AND_SWP;
endfunction

function Bool workReqHasSwap(WorkReqOpCode opcode);
    return case (opcode)
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD: True;
        default: False;
    endcase;
endfunction

function Bool isAtomicWorkReq(WorkReqOpCode opcode);
    return workReqHasSwap(opcode);
endfunction

function Bool isReadWorkReq(WorkReqOpCode opcode);
    return opcode == IBV_WR_RDMA_READ;
endfunction

function Bool isReadOrAtomicWorkReq(WorkReqOpCode opcode);
    return case (opcode)
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD: True;
        default: False;
    endcase;
endfunction

function Bool workReqHasImmDt(WorkReqOpCode opcode);
    return case (opcode)
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_SEND_WITH_IMM: True;
        default: False;
    endcase;
endfunction

function Bool workReqHasInv(WorkReqOpCode opcode);
    return opcode == IBV_WR_SEND_WITH_INV;
endfunction

// WorkComp related

function Maybe#(WorkCompOpCode) workReqOpCode2WorkCompOpCode4SQ(WorkReqOpCode wrOpCode);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          : tagged Valid IBV_WC_RDMA_WRITE;
        IBV_WR_RDMA_WRITE_WITH_IMM : tagged Valid IBV_WC_RDMA_WRITE;
        IBV_WR_SEND                : tagged Valid IBV_WC_SEND;
        IBV_WR_SEND_WITH_IMM       : tagged Valid IBV_WC_SEND;
        IBV_WR_RDMA_READ           : tagged Valid IBV_WC_RDMA_READ;
        IBV_WR_ATOMIC_CMP_AND_SWP  : tagged Valid IBV_WC_COMP_SWAP;
        IBV_WR_ATOMIC_FETCH_AND_ADD: tagged Valid IBV_WC_FETCH_ADD;
        IBV_WR_LOCAL_INV           : tagged Valid IBV_WC_LOCAL_INV;
        IBV_WR_BIND_MW             : tagged Valid IBV_WC_BIND_MW;
        IBV_WR_SEND_WITH_INV       : tagged Valid IBV_WC_SEND;

        default                    : tagged Invalid;
    endcase;
endfunction

function WorkCompFlags workReqOpCode2WorkCompFlags(WorkReqOpCode wrOpCode);
    return case (wrOpCode)
        IBV_WR_RDMA_WRITE          ,
        IBV_WR_SEND                ,
        IBV_WR_RDMA_READ           ,
        IBV_WR_ATOMIC_CMP_AND_SWP  ,
        IBV_WR_ATOMIC_FETCH_AND_ADD,
        IBV_WR_BIND_MW             : IBV_WC_NO_FLAGS;
        IBV_WR_RDMA_WRITE_WITH_IMM ,
        IBV_WR_SEND_WITH_IMM       : IBV_WC_WITH_IMM;
        IBV_WR_LOCAL_INV           ,
        IBV_WR_SEND_WITH_INV       : IBV_WC_WITH_INV;

        default                    : IBV_WC_NO_FLAGS;
    endcase;
endfunction

function Maybe#(WorkCompOpCode) rdmaOpCode2WorkCompOpCode4RQ(RdmaOpCode opcode);
    return case (opcode)
        SEND_FIRST                    ,
        SEND_MIDDLE                   ,
        SEND_LAST                     ,
        SEND_LAST_WITH_IMMEDIATE      ,
        SEND_ONLY                     ,
        SEND_ONLY_WITH_IMMEDIATE      : tagged Valid IBV_WC_RECV;

        RDMA_WRITE_LAST_WITH_IMMEDIATE,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE: tagged Valid IBV_WC_RECV_RDMA_WITH_IMM;

        default                       : tagged Invalid;
    endcase;
endfunction

function WorkCompFlags rdmaOpCode2WorkCompFlags(RdmaOpCode opcode);
    return case (opcode)
        SEND_FIRST                    ,
        SEND_MIDDLE                   ,
        SEND_LAST                     ,
        SEND_ONLY                     : IBV_WC_NO_FLAGS;

        SEND_LAST_WITH_IMMEDIATE      ,
        SEND_ONLY_WITH_IMMEDIATE      ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE: IBV_WC_WITH_IMM;

        SEND_LAST_WITH_INVALIDATE     ,
        SEND_ONLY_WITH_INVALIDATE     : IBV_WC_WITH_INV;

        default                       : IBV_WC_NO_FLAGS;
    endcase;
endfunction

function Maybe#(WorkCompStatus) genWorkCompStatusFromAETH(AETH aeth);
    case (aeth.code)
        AETH_CODE_ACK: return tagged Valid IBV_WC_SUCCESS;
        AETH_CODE_RNR: return tagged Valid IBV_WC_RNR_RETRY_EXC_ERR;
        AETH_CODE_NAK: return case (aeth.value)
            zeroExtend(pack(AETH_NAK_SEQ_ERR)): tagged Valid IBV_WC_RETRY_EXC_ERR;
            zeroExtend(pack(AETH_NAK_INV_REQ)): tagged Valid IBV_WC_REM_INV_REQ_ERR;
            zeroExtend(pack(AETH_NAK_RMT_ACC)): tagged Valid IBV_WC_REM_ACCESS_ERR;
            zeroExtend(pack(AETH_NAK_RMT_OP)) : tagged Valid IBV_WC_REM_OP_ERR;
            zeroExtend(pack(AETH_NAK_INV_RD)) : tagged Valid IBV_WC_REM_INV_RD_REQ_ERR;
            default                           : tagged Invalid;
        endcase;
        // AETH_CODE_RSVD
        default: return tagged Invalid;
    endcase
endfunction

// Payload related

module mkSegmentDataStreamByPmtu#(
    DataStreamPipeOut dataStreamPipeIn, PMTU pmtu
)(DataStreamPipeOut);
    PmtuFragNum pmtuFragNum = calcFragNumByPmtu(pmtu);
    Reg#(PmtuFragNum) fragCntReg <- mkRegU;
    FIFOF#(DataStream) dataQ <- mkFIFOF;
    Reg#(Bool) setFirstReg <- mkReg(False);
    Bool isFragCntZero = isZero(fragCntReg);

    rule enq;
        let curData = dataStreamPipeIn.first;
        dataStreamPipeIn.deq;

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
/*
// module mkDataStreamFromDmaReadResp#(PipeOut#(DmaReadResp) respPipeOut)(DataStreamPipeOut);
//     function DataStream getDmaReadRespData(DmaReadResp dmaReadResp) = dmaReadResp.data;
//     DataStreamPipeOut ret <- mkFunc2Pipe(getDmaReadRespData, respPipeOut);
//     return ret;
// endmodule

module mkSegDataStreamPipeOutFromDmaReadResp#(
    Get#(DmaReadResp) resp,
    PMTU pmtu
)(DataStreamPipeOut);
    DataStreamPipeOut dataStreamPipeOut <-
        mkDataStreamPipeOutFromDmaReadResp(resp);
    let ret <- mkSegmentDataStreamByPmtu(dataStreamPipeOut, pmtu);
    return ret;
endmodule

// module mkSegDataStreamPipeOutFromDmaReadResp#(
//     Get#(DmaReadResp) resp,
//     PMTU pmtu,
//     WorkReqID wrID
// )(DataStreamPipeOut);
//     function Action checkDmaReadResp(DmaReadResp resp);
//         action
//             dynAssert(
//                 resp.wrID == wrID,
//                 "wrID assertion @ mkSegDataStreamPipeOutFromDmaReadResp",
//                 $format("resp.wrID=%h should == wrID=%h", resp.wrID, wrID)
//             );
//         endaction
//     endfunction
//     function DataStream getDmaReadRespData(DmaReadResp dmaReadResp) = dmaReadResp.data;

//     PipeOut#(DmaReadResp) dmaReadRespPipeOut <- mkSource_from_fav(resp.get);
//     DataStreamPipeOut dataStreamPipeOut <- mkFunc2Pipe(
//         getDmaReadRespData,
//         fn_tee_to_Action(checkDmaReadResp, dmaReadRespPipeOut)
//     );
//     let ret <- mkSegmentDataStreamByPmtu(dataStreamPipeOut, pmtu);
//     return ret;
// endmodule
*/
// PipeOut related

function PipeOut#(anytype) convertFifo2PipeOut(FIFOF#(anytype) outputQ);
    return f_FIFOF_to_PipeOut(outputQ);
endfunction

// function PipeOut #(ta) applyActionFunc2PipeOut(
//     function Action afn (ta inputVal),
//     PipeOut #(ta) pipeIn
// );
//     return fn_tee_to_Action(afn, pipeIn)
// endfunction
module mkPipeFilter#(
    function Bool filterF(anytype in),
    PipeOut#(anytype) pipeIn
)(PipeOut#(anytype)) provisos (Bits #(anytype, aSz));
    FIFOF#(anytype) outQ <- mkFIFOF;

    rule rl_into_buffer;
        if (filterF(pipeIn.first)) begin
            outQ.enq (pipeIn.first);
        end
        pipeIn.deq;
    endrule

    return convertFifo2PipeOut(outQ);
endmodule

module mkConstantPipeOut#(anytype constant)(PipeOut #(anytype));
    PipeOut#(anytype) ret <- mkSource_from_constant(constant);
    return ret;
endmodule

module mkBufferN#(
    Integer depth, PipeOut#(anytype) pipeIn
)(PipeOut#(anytype)) provisos(Bits#(anytype, tSz));
    let ret <- mkBuffer_n(depth, pipeIn);
    return ret;
endmodule

module mkFunc2Pipe#(
    function tb func(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut#(tb));
    let ret <- mkFn_to_Pipe(func, pipeIn); // No delay
    return ret;
endmodule

module mkActionValueFunc2Pipe#(
    function ActionValue#(tb) avfn(ta inputVal), PipeOut#(ta) pipeIn
)(PipeOut #(tb)) provisos (Bits #(ta, taSz), Bits #(tb, tbSz));
    // let ret <- mkTap(avfn, pipeIn); // No delay
    let ret <- mkAVFn_to_Pipe(avfn, pipeIn); // One cycle delay
    return ret;
endmodule

module mkMuxPipeOut#(
    Bool sel, PipeOut#(anytype) pipeIn1, PipeOut#(anytype) pipeIn2
)(PipeOut#(anytype));
    method anytype first();
        return sel ? pipeIn1.first : pipeIn2.first;
    endmethod

    method Action deq();
        if (sel) begin
            pipeIn1.deq;
        end
        else begin
            pipeIn2.deq;
        end
    endmethod

    method Bool notEmpty();
        return sel ? pipeIn1.notEmpty : pipeIn2.notEmpty;
    endmethod
endmodule

function Tuple2#(PipeOut#(anytype), PipeOut#(anytype)) deMuxPipeOut(
    Bool sel, PipeOut#(anytype) pipeIn
);
    PipeOut#(anytype) p1 = interface PipeOut;
        method anytype first() if (sel);
            return pipeIn.first;
        endmethod
        method Action deq if (sel);
            pipeIn.deq;
        endmethod
        method Bool notEmpty if (sel);
            return pipeIn.notEmpty;
        endmethod
    endinterface;

    PipeOut#(anytype) p2 = interface PipeOut;
        method anytype first() if (!sel);
            return pipeIn.first;
        endmethod
        method Action deq if (!sel);
            pipeIn.deq;
        endmethod
        method Bool notEmpty if (!sel);
            return pipeIn.notEmpty;
        endmethod
    endinterface;

    return tuple2(p1, p2);
endfunction
