import Arbitration :: *;
import BRAMFIFO :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;

typedef Bit#(32)  AddrIPv4;
typedef Bit#(128) AddrIPv6;

typedef union tagged {
    AddrIPv4 IPv4;
    AddrIPv6 IPv6;
} IP deriving(Bits);

instance FShow#(IP);
    function Fmt fshow(IP ipAddr);
        case (ipAddr) matches
            tagged IPv4 .ipv4: begin
                return $format(
                    "ipv4=%d.%d.%d.%d",
                    ipv4[31 : 24], ipv4[23: 16], ipv4[15 : 8], ipv4[7 : 0]
                );
            end
            tagged IPv6 .ipv6: begin
                return $format(
                    "ipv6=%h:%h:%h:%h:%h:%h:%h:%h",
                    ipv6[127 : 112], ipv6[111: 96], ipv6[95 : 80], ipv6[79 : 64],
                    ipv6[63 : 48], ipv6[47: 32], ipv6[31 : 16], ipv6[15 : 0]
                );
            end
        endcase
    endfunction
endinstance

typedef union tagged {
    IMM  ImmDt;
    RKEY RKey2Inv;
} ImmDtOrInvRKey deriving(Bits, FShow);

typedef struct {
    WorkReqID id; // TODO: remove it
    WorkReqOpCode opcode;
    FlagsType#(WorkReqSendFlag) flags;
    TypeQP qpType;
    PSN curPSN;
    PMTU pmtu;
    IP dqpIP;
    ScatterGatherList sgl;
    ADDR raddr;
    RKEY rkey;
    // ADDR laddr;
    // Length len;
    // LKEY lkey;
    QPN sqpn; // TODO: remove it
    Bool solicited; // Relevant only for the Send and RDMA Write with immediate data
    // Maybe#(Long) comp;
    // Maybe#(Long) swap;
    Maybe#(ImmDtOrInvRKey) immDtOrInvRKey;
    Maybe#(QPN) srqn; // for XRC
    Maybe#(QPN) dqpn; // for UD
    Maybe#(QKEY) qkey; // for UD
} WorkQueueElem deriving(Bits);

instance FShow#(WorkQueueElem);
    function Fmt fshow(WorkQueueElem wqe);
        return $format(
            "WorkQueueElem { opcode=", fshow(wqe.opcode),
            ", flags=", fshow(wqe.flags),
            ", qpType=", fshow(wqe.qpType),
            ", curPSN=%h", wqe.curPSN,
            ", pmtu=", fshow(wqe.pmtu),
            ", dqpIP=", fshow(wqe.dqpIP),
            ", sgl=", fshow(wqe.sgl),
            ", rkey=%h", wqe.rkey,
            ", raddr=%h", wqe.raddr,
            // ", sqpn=%h", wqe.sqpn,
            // ", sqpn=%h", wqe.sqpn,
            ", solicited=", fshow(wqe.solicited),
            // ", comp=", fshow(wqe.comp), ", swap=", fshow(wqe.swap),
            ", immDtOrInvRKey=", fshow(wqe.immDtOrInvRKey),
            ", srqn=", fshow(wqe.srqn),
            ", dqpn=", fshow(wqe.dqpn),
            ", qkey=", fshow(wqe.qkey), " }"
        );
    endfunction
endinstance

typedef struct {
    ADDR   laddr;
    Length len;
    LKEY   lkey;
    Bool   isFirst;
    Bool   isLast;
} ScatterGatherElem deriving(Bits, FShow);

typedef Vector#(MAX_SGE, ScatterGatherElem) ScatterGatherList;

// typedef struct {
//     // The last fragment ByteEn for each packet of the SGE
//     ByteEnBitNum curPktLastFragValidByteNum;
//     PktLen       pktLen;
//     PMTU         pmtu;
//     Bool         sgeHasJustTwoPkts;
//     Bool         isFirst;
//     Bool         isLast;
//     Bool         isFirstSGE;
//     Bool         isLastSGE;
// } PktMetaDataSGE deriving(Bits, FShow);

typedef struct {
    PktLen firstPktLen;
    PktLen lastPktLen;
    PktNum sgePktNum;
    PMTU   pmtu;
} PktMetaDataSGE deriving(Bits, FShow);

typedef struct {
    // PktLen       lastPktLen;
    // PktFragNum   lastPktFragNum;
    // PktNum       sgePktNum;
    ByteEnBitNum lastFragValidByteNum;
    Bool         isFirst;
    Bool         isLast;
} MergedMetaDataSGE deriving(Bits, FShow);

typedef struct {
    QPN       sqpn; // TODO: remove it
    WorkReqID wrID; // TODO: remove it
    Length    totalLen;
    PMTU      pmtu;
    // NumSGE    sgeNum;
    // PktFragNum pmtuFragNum;
    // PktLen pmtuLen;
} TotalPayloadLenMetaDataSGL deriving(Bits, FShow);

typedef struct {
    // QPN          sqpn; // TODO: remove it
    // WorkReqID    wrID; // TODO: remove it
    PktLen       firstPktLen;
    PktFragNum   firstPktFragNum;
    ByteEnBitNum firstPktLastFragValidByteNum;
    // PAD          firstPktPadCnt;
    // ByteEn       firstPktLastFragByteEn;
    // PktLen       lastPktLen;
    // PktFragNum   lastPktFragNum;
    // ByteEnBitNum lastPktLastFragValidByteNum;
    // PAD          lastPktPadCnt;
    // ByteEn       lastPktLastFragByteEn;
    ByteEnBitNum origLastFragValidByteNum;
    // PktLen       pmtuLen;
    PktNum       adjustedPktNum;
    PktNum       origPktNum;
    PMTU         pmtu;
    // Length       totalLen;
} AdjustedTotalPayloadMetaData deriving(Bits, FShow);

typedef struct {
    // DmaReqSrcType initiator;
    ScatterGatherList sgl;
    QPN sqpn; // TODO: remove it
    // ADDR startAddr;
    // Length len;
    WorkReqID wrID; // TODO: remove it
} DmaReadMetaDataSGL deriving(Bits, FShow);

typedef struct {
    ADDR   startAddr;
    Length len;
    PMTU   pmtu;
    Bool   isFirst;
    Bool   isLast;
} AddrChunkReq deriving(Bits, FShow);

typedef struct {
    ADDR   chunkAddr;
    PktLen chunkLen;
    Bool   isFirst;
    Bool   isLast;
    Bool   isOrigFirst;
    Bool   isOrigLast;
} AddrChunkResp deriving(Bits, FShow);

function ADDR alignAddrByPMTU(ADDR addr, PMTU pmtu);
    return case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            { addr[valueOf(ADDR_WIDTH)-1 : 8], 8'b0 };
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            { addr[valueOf(ADDR_WIDTH)-1 : 9], 9'b0 };
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            { addr[valueOf(ADDR_WIDTH)-1 : 10], 10'b0 };
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            { addr[valueOf(ADDR_WIDTH)-1 : 11], 11'b0 };
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            { addr[valueOf(ADDR_WIDTH)-1 : 12], 12'b0 };
        end
    endcase;
endfunction

function Tuple5#(PktLen, PktLen, PktLen, PktNum, ADDR) calcPktNumAndPktLenByAddrAndPMTU(
    ADDR startAddr, Length len, PMTU pmtu
);
    let oneAsPSN = 1;
    let pmtuAlignedStartAddr = alignAddrByPMTU(startAddr, pmtu);
    let secondChunkStartAddr = addrAddPsnMultiplyPMTU(pmtuAlignedStartAddr, oneAsPSN, pmtu);
    let pmtuLen = calcPmtuLen(pmtu);

    Tuple4#(PktLen, PktNum, PktLen, PktLen) tmpTuple = case (pmtu)
        IBV_MTU_256 : begin
            Bit#(8) addrLowPart = truncate(startAddr); // [7 : 0]
            Bit#(8) lenLowPart = truncate(len);
            Bit#(8) pmtuMask = maxBound;
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) truncatedLen = truncateLSB(len);
            tuple4(zeroExtend(pmtuMask), zeroExtend(truncatedLen), zeroExtend(addrLowPart), zeroExtend(lenLowPart));
        end
        IBV_MTU_512 : begin
            Bit#(9) addrLowPart = truncate(startAddr); // [8 : 0]
            Bit#(9) lenLowPart = truncate(len);
            Bit#(9) pmtuMask = maxBound;
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) truncatedLen = truncateLSB(len);
            tuple4(zeroExtend(pmtuMask), zeroExtend(truncatedLen), zeroExtend(addrLowPart), zeroExtend(lenLowPart));
        end
        IBV_MTU_1024: begin
            Bit#(10) addrLowPart = truncate(startAddr); // [9 : 0]
            Bit#(10) lenLowPart = truncate(len);
            Bit#(10) pmtuMask = maxBound;
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) truncatedLen = truncateLSB(len);
            tuple4(zeroExtend(pmtuMask), zeroExtend(truncatedLen), zeroExtend(addrLowPart), zeroExtend(lenLowPart));
        end
        IBV_MTU_2048: begin
            Bit#(11) addrLowPart = truncate(startAddr); // [10 : 0]
            Bit#(11) lenLowPart = truncate(len);
            Bit#(11) pmtuMask = maxBound;
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) truncatedLen = truncateLSB(len);
            tuple4(zeroExtend(pmtuMask), zeroExtend(truncatedLen), zeroExtend(addrLowPart), zeroExtend(lenLowPart));
        end
        IBV_MTU_4096: begin
            Bit#(12) addrLowPart = truncate(startAddr); // [11 : 0]
            Bit#(12) lenLowPart = truncate(len);
            Bit#(12) pmtuMask = maxBound;
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) truncatedLen = truncateLSB(len);
            tuple4(zeroExtend(pmtuMask), zeroExtend(truncatedLen), zeroExtend(addrLowPart), zeroExtend(lenLowPart));
        end
    endcase;

    let { pmtuMask, truncatedPktNum, addrLowPart, lenLowPart } = tmpTuple;
    let maxFirstPktLen = pmtuLen - addrLowPart;
    let tmpSum = addrLowPart + lenLowPart;
    ResiduePMTU residue = truncateByPMTU(tmpSum, pmtu);
    PktLen tmpLastPktLen = zeroExtend(residue);

    let pmtuInvMask = ~pmtuMask;
    let residuePktNum = |(pmtuMask & tmpSum);
    let extraPktNum = |(pmtuInvMask & tmpSum);
    Bool hasResidue = unpack(residuePktNum);
    Bool hasExtraPkt = unpack(extraPktNum);
    let notFullPkt = isZeroR(truncatedPktNum);

    let totalPktNum = truncatedPktNum + zeroExtend(residuePktNum) + zeroExtend(extraPktNum);
    // let firstPktLen = notFullPkt ? (hasExtraPkt ? maxFirstPktLen : lenLowPart) : maxFirstPktLen;
    let firstPktLen = (notFullPkt && !hasExtraPkt) ? lenLowPart : maxFirstPktLen;
    // let lastPktLen = notFullPkt ? (hasResidue ? tmpLastPktLen : 0) : (hasResidue ? tmpLastPktLen : pmtuLen);
    let lastPktLen = notFullPkt ? (hasExtraPkt ? tmpLastPktLen : lenLowPart) : (hasResidue ? tmpLastPktLen : pmtuLen);
    // let isSinglePkt = isLessOrEqOneR(totalPktNum);

    return tuple5(pmtuLen, firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr);
endfunction

function PktFragNum calcFragNumByPktLen(PktLen pktLen) provisos(
    Add#(PMTU_FRAG_NUM_WIDTH, DATA_BUS_BYTE_NUM_WIDTH, PKT_LEN_WIDTH)
);
    BusByteWidthMask lastFragByteNumResidue = truncate(pktLen);
    // Bit#(TSub#(PKT_LEN_WIDTH, DATA_BUS_BYTE_NUM_WIDTH)) truncatedPktLen =
    PktFragNum truncatedPktLen = truncateLSB(pktLen);
    let pktFragNum = truncatedPktLen + zeroExtend(pack(!isZeroR(lastFragByteNumResidue)));
    return pktFragNum;
endfunction

function Tuple2#(PktLen, PktNum) calcPktNumAndLastPktLenByPMTU(Length len, PMTU pmtu);
    let pmtuLen = calcPmtuLen(pmtu);

    Tuple2#(PktNum, PktLen) tmpTuple = case (pmtu)
        IBV_MTU_256 : begin
            Bit#(8) lenLowPart = truncate(len); // [7 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) truncatedLen = truncateLSB(len);
            tuple2(zeroExtend(truncatedLen), zeroExtend(lenLowPart));
        end
        IBV_MTU_512 : begin
            Bit#(9) lenLowPart = truncate(len); // [8 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) truncatedLen = truncateLSB(len);
            tuple2(zeroExtend(truncatedLen), zeroExtend(lenLowPart));
        end
        IBV_MTU_1024: begin
            Bit#(10) lenLowPart = truncate(len); // [9 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) truncatedLen = truncateLSB(len);
            tuple2(zeroExtend(truncatedLen), zeroExtend(lenLowPart));
        end
        IBV_MTU_2048: begin
            Bit#(11) lenLowPart = truncate(len); // [10 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) truncatedLen = truncateLSB(len);
            tuple2(zeroExtend(truncatedLen), zeroExtend(lenLowPart));
        end
        IBV_MTU_4096: begin
            Bit#(12) lenLowPart = truncate(len); // [11 : 0]
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) truncatedLen = truncateLSB(len);
            tuple2(zeroExtend(truncatedLen), zeroExtend(lenLowPart));
        end
    endcase;

    let { truncatedPktNum, residuePktLen } = tmpTuple;
    let residuePktNum = |residuePktLen;
    Bool hasResidue = unpack(residuePktNum);
    let noFullPkt = isZeroR(truncatedPktNum);

    let totalPktNum = truncatedPktNum + zeroExtend(residuePktNum);
    let lastPktLen = noFullPkt ? (hasResidue ? residuePktLen : 0) : (hasResidue ? residuePktLen : pmtuLen);
    // let isSinglePkt = isLessOrEqOneR(totalPktNum);

    return tuple2(lastPktLen, totalPktNum);
endfunction

function DataStream mergeFragData(
    DataStream preFrag,
    DataStream curFrag,
    ByteEnBitNum preFragInvalidByteNum,
    BusBitNum preFragInvalidBitNum
);
    let resultFrag = preFrag;
    resultFrag.byteEn = truncateLSB({ preFrag.byteEn, curFrag.byteEn } << preFragInvalidByteNum);
    resultFrag.data = truncateLSB({ preFrag.data, curFrag.data } << preFragInvalidBitNum);
    return resultFrag;
endfunction

interface AddrChunkSrv;
    interface Server#(AddrChunkReq, AddrChunkResp) srvPort;
    interface PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeOut;
    method Bool isIdle();
endinterface

// TODO: refactor AddrChunkSrv into fully pipeline
module mkAddrChunkSrv#(Bool clearAll)(AddrChunkSrv);
    FIFOF#(AddrChunkReq)           reqQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(AddrChunkResp)         respQ <- mkFIFOF;
    FIFOF#(PktMetaDataSGE) sgePktMetaDataOutQ <- mkFIFOF;

    Reg#(PktLen)  firstPktLenReg <- mkRegU;
    Reg#(PktLen)   fullPktLenReg <- mkRegU;
    Reg#(PktLen)   lastPktLenReg <- mkRegU;
    Reg#(Bool)    isOrigFirstReg <- mkRegU;
    Reg#(Bool)     isOrigLastReg <- mkRegU;

    Reg#(PktNum) remainingPktNumReg <- mkRegU;

    Reg#(ADDR)   chunkAddrReg <- mkRegU;
    Reg#(ADDR)    nextAddrReg <- mkRegU;
    Reg#(PMTU)        pmtuReg <- mkRegU;
    Reg#(Bool)     isFirstReg <- mkRegU;
    Reg#(Bool)        busyReg <- mkReg(False);

    PSN oneAsPSN = 1;

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        busyReg <= False;
    endrule

    rule recvReq if (!clearAll && !busyReg);
        let addrChunkReq = reqQ.first;
        reqQ.deq;

        immAssert(
            !isZeroR(addrChunkReq.len),
            "addrChunkReq.len assertion @ mkAddrChunkSrv",
            $format(
                "addrChunkReq.len=%0d cannot be zero", addrChunkReq.len
            )
        );

        let {
            pmtuLen, firstPktLen, lastPktLen, sgePktNum, secondChunkStartAddr //, isSinglePkt
        } = calcPktNumAndPktLenByAddrAndPMTU(
            addrChunkReq.startAddr, addrChunkReq.len, addrChunkReq.pmtu
        );
        remainingPktNumReg <= sgePktNum - 1;

        firstPktLenReg   <= firstPktLen;
        fullPktLenReg    <= pmtuLen;
        lastPktLenReg    <= lastPktLen;
        chunkAddrReg     <= addrChunkReq.startAddr;
        nextAddrReg      <= secondChunkStartAddr;
        pmtuReg          <= addrChunkReq.pmtu;
        isOrigFirstReg   <= addrChunkReq.isFirst;
        isOrigLastReg    <= addrChunkReq.isLast;
        isFirstReg       <= True;
        busyReg          <= True;

        let sgePktMetaData = PktMetaDataSGE {
            firstPktLen: firstPktLen,
            lastPktLen : lastPktLen,
            sgePktNum  : sgePktNum,
            pmtu       : addrChunkReq.pmtu
        };
        sgePktMetaDataOutQ.enq(sgePktMetaData);

        // $display(
        //     "time=%0t: mkAddrChunkSrv recvReq", $time,
        //     ", addrChunkReq.len=%0d", addrChunkReq.len,
        //     ", sgePktNum=%0d", sgePktNum,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen
        // );
    endrule

    rule genResp if (!clearAll && busyReg);
        let isLast = isZeroR(remainingPktNumReg);
        if (!isLast) begin
            remainingPktNumReg <= remainingPktNumReg - 1;
        end

        busyReg      <= !isLast;
        isFirstReg   <= False;
        chunkAddrReg <= nextAddrReg;
        nextAddrReg  <= addrAddPsnMultiplyPMTU(nextAddrReg, oneAsPSN, pmtuReg);

        let chunkLen = isFirstReg ? firstPktLenReg : (isLast ? lastPktLenReg : fullPktLenReg);
        let addrChunkResp = AddrChunkResp {
            chunkAddr  : chunkAddrReg,
            chunkLen   : chunkLen,
            isFirst    : isFirstReg,
            isLast     : isLast,
            isOrigFirst: isOrigFirstReg,
            isOrigLast : isOrigLastReg
        };
        respQ.enq(addrChunkResp);
/*
        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(firstPktLenReg);
        let lastPktLastFragValidByteNum = calcLastFragValidByteNum(lastPktLenReg);
        let curPktLastFragValidByteNum = isFirstReg ?
            firstPktLastFragValidByteNum : (
                isLast ? lastPktLastFragValidByteNum : fromInteger(valueOf(DATA_BUS_BYTE_WIDTH))
            );

        let sgePktMetaData = PktMetaDataSGE {
            curPktLastFragValidByteNum: curPktLastFragValidByteNum,
            pktLen                    : chunkLen,
            pmtu                      : pmtuReg,
            sgeHasJustTwoPkts             : isTwoR(sgePktNumReg),
            isFirst                   : isFirstReg,
            isLast                    : isLast,
            isFirstSGE                : isOrigFirstReg,
            isLastSGE                 : isOrigLastReg
        };
        sgePktMetaDataOutQ.enq(sgePktMetaData);
*/
        // $display(
        //     "time=%0t: mkAddrChunkSrv genResp", $time,
        //     ", isSQ=", fshow(isSQ),
        //     ", remainingPktNumReg=%0d", remainingPktNumReg,
        //     ", chunkAddrReg=%h", chunkAddrReg,
        //     ", nextAddrReg=%h", nextAddrReg,
        //     ", addrChunkResp=", fshow(addrChunkResp)
        // );
    endrule

    interface srvPort = toGPServer(reqQ, respQ);
    interface sgePktMetaDataPipeOut = toPipeOut(sgePktMetaDataOutQ);
    method Bool isIdle() = !busyReg &&
        !reqQ.notEmpty && !sgePktMetaDataOutQ.notEmpty && !respQ.notEmpty;
endmodule

typedef struct {
    // DmaReqSrcType     initiator;
    DmaReadMetaDataSGL sglDmaReadMetaData;
    PMTU               pmtu;
} DmaReadCntrlReq deriving(Bits, FShow);

typedef struct {
    DmaReadResp dmaReadResp;
    Bool        isOrigFirst;
    Bool        isOrigLast;
} DmaReadCntrlResp deriving(Bits, FShow);

typedef Server#(DmaReadCntrlReq, DmaReadCntrlResp) DmaCntrlReadSrv;

interface DmaCntrl;
    method Bool isIdle();
    method Action cancel();
endinterface

interface DmaReadCntrl;
    interface DmaCntrlReadSrv srvPort;
    interface DmaCntrl dmaCntrl;
    interface PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeOut;
    interface PipeOut#(TotalPayloadLenMetaDataSGL) sglTotalPayloadLenMetaDataPipeOut;
    interface PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeOut;
endinterface

module mkDmaReadCntrl#(
    Bool clearAll, DmaReadSrv dmaReadSrv
)(DmaReadCntrl);
    FIFOF#(DmaReadCntrlReq)   reqQ <- mkFIFOF;
    FIFOF#(DmaReadCntrlResp) respQ <- mkFIFOF;
    FIFOF#(MergedMetaDataSGE)       sgeMergedMetaDataOutQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(TotalPayloadLenMetaDataSGL) sglTotalPayloadLenMetaDataOutQ <- mkFIFOF;

    FIFOF#(Tuple2#(QPN, WorkReqID)) pendingDmaCntrlReqQ <- mkFIFOF; // TODO: remove it
    FIFOF#(Tuple2#(Bool, Bool))     pendingDmaReadReqQ <- mkFIFOF;
    FIFOF#(Tuple2#(ScatterGatherElem, PMTU)) pendingScatterGatherElemQ <- mkSizedFIFOF(valueOf(MAX_SGE));

    let addrChunkSrv <- mkAddrChunkSrv(clearAll);

    Reg#(Bool) gracefulStopReg[2] <- mkCReg(2, False);
    Reg#(Bool)       cancelReg[2] <- mkCReg(2, False);

    Reg#(Length) totalLenReg <- mkRegU;
    Reg#(NumSGE)   sgeNumReg <- mkRegU;
    Reg#(IdxSGL)   sglIdxReg <- mkReg(0);

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;

        pendingDmaCntrlReqQ.clear;
        pendingScatterGatherElemQ.clear;
        pendingDmaReadReqQ.clear;

        cancelReg[1]       <= False;
        gracefulStopReg[1] <= False;

        sglIdxReg <= 0;
        // $display("time=%0t: resetAndClear", $time);
    endrule

    (* conflict_free = "recvReq, \
                        issueChunkReq, \
                        issueDmaReq, \
                        recvDmaResp" *)
    rule recvReq if (!clearAll && !cancelReg[1]);
        let dmaReadCntrlReq = reqQ.first;

        let sglIdx = sglIdxReg;
        let sge = dmaReadCntrlReq.sglDmaReadMetaData.sgl[sglIdx];
        immAssert(
            !isZeroR(sge.len),
            "zero SGE assertion @ mkDmaReadCntrl",
            $format(
                "sge.len=%d", sge.len,
                " should not be zero when sglIdxReg=%d", sglIdxReg
            )
        );

        let mergedLastPktLastFragValidByteNum =
            calcLastFragValidByteNum(sge.len);
        let sgeMergedMetaData = MergedMetaDataSGE {
            lastFragValidByteNum: mergedLastPktLastFragValidByteNum,
            isFirst             : sge.isFirst,
            isLast              : sge.isLast
        };
        sgeMergedMetaDataOutQ.enq(sgeMergedMetaData);
        pendingScatterGatherElemQ.enq(tuple2(sge, dmaReadCntrlReq.pmtu));
        // let addrChunkReq = AddrChunkReq {
        //     startAddr: sge.laddr,
        //     len      : sge.len,
        //     pmtu     : dmaReadCntrlReq.pmtu,
        //     isFirst  : sge.isFirst,
        //     isLast   : sge.isLast
        // };
        // addrChunkSrv.srvPort.request.put(addrChunkReq);

        let curSQPN = dmaReadCntrlReq.sglDmaReadMetaData.sqpn;
        let curWorkReqID = dmaReadCntrlReq.sglDmaReadMetaData.wrID;
        let totalLen = totalLenReg;
        let sgeNum = sgeNumReg;
        if (sge.isFirst) begin
            totalLen = sge.len;
            sgeNum = 1;

            pendingDmaCntrlReqQ.enq(tuple2(curSQPN, curWorkReqID));
        end
        else begin
            totalLen = totalLenReg + sge.len;
            sgeNum = sgeNumReg + 1;
        end
        totalLenReg <= totalLen;
        sgeNumReg <= sgeNum;
        // $display(
        //     "time=%0t: recvReq", $time,
        //     ", SGE sglIdx=%0d", sglIdx,
        //     ", sge.laddr=%h", sge.laddr,
        //     ", mergedLastPktLastFragValidByteNum=%0d", mergedLastPktLastFragValidByteNum,
        //     ", totalLen=%0d", totalLen,
        //     ", sgeNum=%0d", sgeNum
        //     // ", sgePktNum=%0d", sgePktNum,
        //     // ", firstPktLen=%0d", firstPktLen,
        //     // ", lastPktLen=%0d", lastPktLen,
        //     // ", pmtuLen=%0d", pmtuLen,
        //     // ", firstPktFragNum=%0d", firstPktFragNum,
        //     // ", lastPktFragNum=%0d", lastPktFragNum
        // );

        // if (sglIdxReg == valueOf(TSub#(MAX_SGE, 1))) begin
        if (isAllOnesR(sglIdxReg)) begin
            immAssert(
                sge.isLast,
                "last SGE assertion @ mkDmaReadCntrl",
                $format(
                    "sge.isLast=", fshow(sge.isLast),
                    " should be true when sglIdxReg=%d", sglIdxReg
                )
            );
        end

        if (sge.isLast) begin
            reqQ.deq;
            sglIdxReg <= 0;

            let sglTotalPayloadLenMetaData = TotalPayloadLenMetaDataSGL {
                sqpn    : curSQPN,
                wrID    : curWorkReqID,
                totalLen: totalLen,
                // sgeNum  : sgeNum,
                pmtu    : dmaReadCntrlReq.pmtu
            };
            sglTotalPayloadLenMetaDataOutQ.enq(sglTotalPayloadLenMetaData);
            // $display(
            //     "time=%0t: mkDmaReadCntrl recvReq", $time,
            //     ", sqpn=%h", curSQPN,
            //     ", sglTotalPayloadLenMetaData=", fshow(sglTotalPayloadLenMetaData)
            // );
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end
        // $display(
        //     "time=%0t: mkDmaReadCntrl recvReq", $time,
        //     ", sqpn=%h", curSQPN,
        //     ", dmaReadCntrlReq=", fshow(dmaReadCntrlReq),
        //     ", addrChunkReq=", fshow(addrChunkReq)
        // );
    endrule

    rule issueChunkReq if (!clearAll && !cancelReg[1]);
        let { sge, pmtu } = pendingScatterGatherElemQ.first;
        pendingScatterGatherElemQ.deq;

        let addrChunkReq = AddrChunkReq {
            startAddr: sge.laddr,
            len      : sge.len,
            pmtu     : pmtu,
            isFirst  : sge.isFirst,
            isLast   : sge.isLast
        };
        addrChunkSrv.srvPort.request.put(addrChunkReq);
    endrule

    rule issueDmaReq if (!clearAll && !cancelReg[1]);
        let addrChunkResp <- addrChunkSrv.srvPort.response.get;

        let { curSQPN, curWorkReqID } = pendingDmaCntrlReqQ.first;
        // let pendingSGE = pendingScatterGatherElemQ.first;

        let dmaReadReq = DmaReadReq {
            initiator: DMA_SRC_SQ_RD,
            sqpn     : curSQPN,
            startAddr: addrChunkResp.chunkAddr,
            len      : addrChunkResp.chunkLen,
            wrID     : curWorkReqID
        };

        dmaReadSrv.request.put(dmaReadReq);

        // let curSGE = pendingScatterGatherElemQ.first;
        // let isFirstDmaReqChunk = addrChunkResp.isFirst && curSGE.isFirst;
        // let isLastDmaReqChunk  = addrChunkResp.isLast && curSGE.isLast;
        let isFirstDmaReqChunk = addrChunkResp.isFirst && addrChunkResp.isOrigFirst;
        let isLastDmaReqChunk  = addrChunkResp.isLast && addrChunkResp.isOrigLast;
        pendingDmaReadReqQ.enq(tuple2(isFirstDmaReqChunk, isLastDmaReqChunk));

        // if (addrChunkResp.isLast) begin
        //     pendingScatterGatherElemQ.deq;
        // end
        if (isLastDmaReqChunk) begin
            pendingDmaCntrlReqQ.deq;
        end
        // $display(
        //     "time=%0t: mkDmaReadCntrl issueDmaReq", $time,
        //     ", sqpn=%h", curSQPN,
        //     ", pendingDmaReadCntrlReq=", fshow(pendingDmaCntrlReqQ.first),
        //     ", addrChunkResp=", fshow(addrChunkResp),
        //     ", dmaReadReq=", fshow(dmaReadReq)
        // );
    endrule

    rule recvDmaResp if (!clearAll);
        let dmaResp <- dmaReadSrv.response.get;

        let { isFirstDmaReqChunk, isLastDmaReqChunk } = pendingDmaReadReqQ.first;

        let isOrigFirst = dmaResp.dataStream.isFirst && isFirstDmaReqChunk;
        let isOrigLast  = dmaResp.dataStream.isLast && isLastDmaReqChunk;

        let dmaReadCntrlResp = DmaReadCntrlResp {
            dmaReadResp: dmaResp,
            isOrigFirst: isOrigFirst,
            isOrigLast : isOrigLast
        };
        respQ.enq(dmaReadCntrlResp);

        if (dmaResp.dataStream.isLast) begin
            pendingDmaReadReqQ.deq;
        end
        // $display(
        //     "time=%0t: mkDmaReadCntrl recvDmaResp", $time,
        //     ", isFirst=", fshow(dmaResp.dataStream.isFirst),
        //     ", isLast=", fshow(dmaResp.dataStream.isLast),
        //     ", isFirstDmaReqChunk=", fshow(isFirstDmaReqChunk),
        //     ", isLastDmaReqChunk=", fshow(isLastDmaReqChunk),
        //     ", isOrigFirst=", fshow(isOrigFirst),
        //     ", isOrigLast=", fshow(isOrigLast)
        // );
    endrule

    rule setGracefulStop if (
        cancelReg[1]                 &&
        !gracefulStopReg[1]          &&
        !respQ.notEmpty              &&
        !pendingDmaReadReqQ.notEmpty &&
        !clearAll
    );
        gracefulStopReg[1] <= True;
        // $display("time=%0t: mkDmaReadCntrl cancel read done", $time);
    endrule

    interface srvPort = toGPServer(reqQ, respQ);

    interface dmaCntrl = interface DmaCntrl;
        method Action cancel();
            cancelReg[0]       <= True;
            gracefulStopReg[0] <= False;
        endmethod

        method Bool isIdle() = gracefulStopReg[0];
    endinterface;

    interface sglTotalPayloadLenMetaDataPipeOut = toPipeOut(sglTotalPayloadLenMetaDataOutQ);
    interface sgeMergedMetaDataPipeOut = toPipeOut(sgeMergedMetaDataOutQ);
    interface sgePktMetaDataPipeOut = addrChunkSrv.sgePktMetaDataPipeOut;
endmodule

typedef enum {
    MERGE_SGE_PAYLOAD_INIT,
    // MERGE_SGE_PAYLOAD_ONLY_PKT,
    // MERGE_SGE_PAYLOAD_FIRST_PKT,
    // MERGE_SGE_PAYLOAD_MID_PKT,
    // MERGE_SGE_PAYLOAD_LAST_PKT,
    MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT,
    MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT
} MergePayloadStateEachSGE deriving(Bits, Eq, FShow);

module mkMergePayloadEachSGE#(
    Bool clearAll,
    PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeIn,
    PipeOut#(DataStream) sgePayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Reg#(ByteEnBitNum)   sgeFirstPktLastFragValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum) sgeFirstPktLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     sgeFirstPktLastFragInvalidBitNumReg <- mkRegU;

    Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(Bool) sgeHasOnlyPktReg <- mkRegU;
    Reg#(Bool) hasExtraFragReg <- mkRegU;
    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(MergePayloadStateEachSGE) stateReg <- mkReg(MERGE_SGE_PAYLOAD_INIT);

    // TODO: emptyDataStream should be an input parameter
    let emptyDataStream = DataStream {
        data: 0,
        byteEn: 0,
        isFirst: False,
        isLast: False
    };

    function ActionValue#(DataStream) prepareNextSGE();
        actionvalue
            let sgePktMetaData = sgePktMetaDataPipeIn.first;
            sgePktMetaDataPipeIn.deq;

            let firstPktLastFragValidByteNum = calcLastFragValidByteNum(sgePktMetaData.firstPktLen);
            let lastPktLastFragValidByteNum = calcLastFragValidByteNum(sgePktMetaData.lastPktLen);

            let {
                firstPktLastFragValidBitNum,
                firstPktLastFragInvalidByteNum,
                firstPktLastFragInvalidBitNum
            } = calcFragBitNumAndByteNum(firstPktLastFragValidByteNum);
            let {
                lastPktLastFragValidBitNum,
                lastPktLastFragInvalidByteNum,
                lastPktLastFragInvalidBitNum
            } = calcFragBitNumAndByteNum(lastPktLastFragValidByteNum);

            let sgeHasJustTwoPkts = isTwoR(sgePktMetaData.sgePktNum);
            let sgeHasOnlyPkt     = isLessOrEqOneR(sgePktMetaData.sgePktNum);
            sgeHasOnlyPktReg     <= sgeHasOnlyPkt;

            let hasExtraFrag = lastPktLastFragValidByteNum > firstPktLastFragInvalidByteNum;
            hasExtraFragReg <= hasExtraFrag;

            // sgeFirstPktLastFragValidByteNumReg   <= firstPktLastFragValidByteNum;
            sgeFirstPktLastFragInvalidByteNumReg <= firstPktLastFragInvalidByteNum;
            sgeFirstPktLastFragInvalidBitNumReg  <= firstPktLastFragInvalidBitNum;

            let curPayloadFrag = sgePayloadPipeIn.first;
            sgePayloadPipeIn.deq;

            let remainingPktNum = 0;
            let isFirstPkt = True;
            let nextPrePayloadFrag = curPayloadFrag;
            if (sgeHasOnlyPkt) begin
                stateReg <= MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT;
            end
            else begin
                if (curPayloadFrag.isLast) begin // Single fragment first packet
                    nextPrePayloadFrag.isLast = False;
                    nextPrePayloadFrag.byteEn = curPayloadFrag.byteEn >> firstPktLastFragInvalidByteNum;
                    nextPrePayloadFrag.data   = curPayloadFrag.data   >> firstPktLastFragInvalidBitNum;

                    isFirstPkt = False;
                    if (sgeHasJustTwoPkts) begin
                        stateReg <= MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT;
                    end
                    else begin
                        stateReg <= MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT;
                        remainingPktNum = sgePktMetaData.sgePktNum - 2;
                    end
                end
                else begin
                    stateReg <= MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT;
                    remainingPktNum = sgePktMetaData.sgePktNum - 1;
                end
            end
            remainingPktNumReg <= remainingPktNum;
            isFirstPktReg  <= isFirstPkt;
            isFirstFragReg <= True;

            // $display(
            //     "time=%0t: prepareNextSGE", $time,
            //     ", sgeHasOnlyPkt=", fshow(sgeHasOnlyPkt),
            //     ", sgeHasJustTwoPkts=", fshow(sgeHasJustTwoPkts),
            //     ", sgePktMetaData.sgePktNum=%0d", sgePktMetaData.sgePktNum,
            //     ", sgePktMetaData.firstPktLen=%0d", sgePktMetaData.firstPktLen,
            //     ", sgePktMetaData.lastPktLen=%0d", sgePktMetaData.lastPktLen,
            //     ", firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
            //     ", firstPktLastFragValidBitNum=%0d", firstPktLastFragValidBitNum,
            //     ", firstPktLastFragInvalidByteNum=%0d", firstPktLastFragInvalidByteNum,
            //     ", firstPktLastFragInvalidBitNum=%0d", firstPktLastFragInvalidBitNum,
            //     // ", sgeFirstPktLastFragValidByteNumReg=%0d", sgeFirstPktLastFragValidByteNumReg,
            //     ", sgeFirstPktLastFragInvalidByteNumReg=%0d", sgeFirstPktLastFragInvalidByteNumReg,
            //     ", sgeFirstPktLastFragInvalidBitNumReg=%0d", sgeFirstPktLastFragInvalidBitNumReg,
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn
            // );
            return nextPrePayloadFrag;
        endactionvalue
    endfunction

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;
        stateReg <= MERGE_SGE_PAYLOAD_INIT;
    endrule

    rule init if (!clearAll && stateReg == MERGE_SGE_PAYLOAD_INIT);
        let nextPrePayloadFrag <- prepareNextSGE;
        prePayloadFragReg <= nextPrePayloadFrag;
    endrule

    rule mergeFirstOrMidPktSGE if (!clearAll && stateReg == MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT);
        let curPayloadFrag = sgePayloadPipeIn.first;
        sgePayloadPipeIn.deq;

        let nextPrePayloadFrag = curPayloadFrag;
        if (curPayloadFrag.isLast) begin
            nextPrePayloadFrag.isLast = False;

            if (isFirstPktReg) begin
                isFirstPktReg <= False;
                // Only right shift the last fragment of the first packet
                nextPrePayloadFrag.byteEn = curPayloadFrag.byteEn >> sgeFirstPktLastFragInvalidByteNumReg;
                nextPrePayloadFrag.data   = curPayloadFrag.data   >> sgeFirstPktLastFragInvalidBitNumReg;
            end

            let isLastPkt = isLessOrEqOneR(remainingPktNumReg);
            if (isLastPkt) begin
                stateReg <= MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT;
            end
            remainingPktNumReg <= remainingPktNumReg - 1;
        end
        prePayloadFragReg <= nextPrePayloadFrag;

        immAssert(
            !isZeroR(remainingPktNumReg),
            "remainingPktNumReg assertion @ mkMergePayloadEachSGE",
            $format(
                "remainingPktNumReg=%0d", fshow(remainingPktNumReg),
                " should > 0 when stateReg=", fshow(stateReg)
            )
        );

        let mergedFrag = mergeFragData(
            prePayloadFragReg, curPayloadFrag,
            sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
        );

        let outPayloadFrag = isFirstPktReg ? prePayloadFragReg : mergedFrag;
        outPayloadFrag.isFirst = isFirstFragReg;
        isFirstFragReg <= False;
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: mergeFirstOrMidPktSGE", $time,
        //     ", sgeFirstPktLastFragInvalidByteNumReg=%0d", sgeFirstPktLastFragInvalidByteNumReg,
        //     ", sgeFirstPktLastFragInvalidBitNumReg=%0d", sgeFirstPktLastFragInvalidBitNumReg,
        //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    rule mergeLastOrOnlyPktSGE if (!clearAll && stateReg == MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT);
        let nextPayloadFrag = emptyDataStream;
        let outPayloadFrag = prePayloadFragReg;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (sgePktMetaDataPipeIn.notEmpty && sgePayloadPipeIn.notEmpty) begin
                nextPayloadFrag <- prepareNextSGE;
            end
            else begin
                // Wait for a packet of next SGE, if no next SGE packet metadata or payload
                stateReg <= MERGE_SGE_PAYLOAD_INIT;
            end
        end
        else begin
            nextPayloadFrag = sgePayloadPipeIn.first;
            sgePayloadPipeIn.deq;

            nextPayloadFrag.isFirst = False;
            if (!sgeHasOnlyPktReg && !hasExtraFragReg && nextPayloadFrag.isLast) begin
                // No extra fragment
                stateReg <= MERGE_SGE_PAYLOAD_INIT;
                isLastFrag = True;
            end
        end
        prePayloadFragReg <= nextPayloadFrag;

        let isLastPkt = isZeroR(remainingPktNumReg);
        immAssert(
            isLastPkt,
            "isLastPkt assertion @ mkMergePayloadEachSGE",
            $format(
                "isLastPkt=", fshow(isLastPkt),
                " should be true when stateReg=", fshow(stateReg),
                ", and remainingPktNumReg=%0d", remainingPktNumReg
            )
        );

        if (!sgeHasOnlyPktReg) begin
            outPayloadFrag = mergeFragData(
                prePayloadFragReg, nextPayloadFrag,
                sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
            );
            outPayloadFrag.isLast = isLastFrag;
        end
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: mergeLastOrOnlyPktSGE", $time,
        //     ", sgeHasOnlyPktReg=", fshow(sgeHasOnlyPktReg),
        //     ", hasExtraFragReg=", fshow(hasExtraFragReg),
        //     ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
        //     ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
        //     ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
        //     ", nextPayloadFrag.isFirst=", fshow(nextPayloadFrag.isFirst),
        //     ", nextPayloadFrag.isLast=", fshow(nextPayloadFrag.isLast),
        //     ", nextPayloadFrag.byteEn=%h", nextPayloadFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule

typedef enum {
    MERGE_SGL_PAYLOAD_INIT,
    MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE,
    MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE
    // MERGE_SGL_PAYLOAD_FIRST_SGE,
    // MERGE_SGL_PAYLOAD_MID_SGE,
    // MERGE_SGL_PAYLOAD_LAST_SGE,
    // MERGE_SGL_PAYLOAD_ONLY_SGE
} MergePayloadStateAllSGE deriving(Bits, Eq, FShow);

module mkMergePayloadAllSGE#(
    Bool clearAll,
    PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeIn,
    PipeOut#(DataStream) sgeMergedPayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Reg#(ByteEnBitNum)    curValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum)  curInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum)      curInvalidBitNumReg <- mkRegU;
    // Reg#(ByteEnBitNum)   nextValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum) nextInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     nextInvalidBitNumReg <- mkRegU;

    Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) sgeIsOnlyReg <- mkRegU;
    Reg#(Bool) sgeIsLastReg <- mkRegU;
    Reg#(Bool) hasLessFragReg <- mkRegU;
    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(MergePayloadStateAllSGE) stateReg <- mkReg(MERGE_SGL_PAYLOAD_INIT);

    BusByteWidthMask busByteNumMask = maxBound;
    BusBitWidthMask  busBitNumMask  = maxBound;

    // TODO: emptyDataStream should be an input parameter
    let emptyDataStream = DataStream {
        data: 0,
        byteEn: 0,
        isFirst: False,
        isLast: False
    };

    function ActionValue#(DataStream) preprocessNextSGL();
        actionvalue
            let sgeMergedMetaData = sgeMergedMetaDataPipeIn.first;
            sgeMergedMetaDataPipeIn.deq;

            let isOnlySGE = sgeMergedMetaData.isFirst && sgeMergedMetaData.isLast;
            sgeIsOnlyReg <= isOnlySGE;
            sgeIsLastReg <= sgeMergedMetaData.isLast;
            isFirstFragReg <= True;

            let lastFragValidByteNum = sgeMergedMetaData.lastFragValidByteNum;
            let hasLessFrag = lastFragValidByteNum < fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
            let curPayloadFrag = sgeMergedPayloadPipeIn.first;
            let nextPrePayloadFrag = curPayloadFrag;

            let nextHasLessFrag = hasLessFrag;
            // If first SGE is single fragment without full byteEn,
            // Wait for the first fragment of next SGE to merge
            if (!isOnlySGE && curPayloadFrag.isLast && hasLessFrag) begin
                nextPrePayloadFrag = emptyDataStream;
                nextHasLessFrag = True;
            end
            else begin
                sgeMergedPayloadPipeIn.deq;
                nextHasLessFrag = False;
            end
            hasLessFragReg <= nextHasLessFrag;

            let {
                lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum
            } = calcFragBitNumAndByteNum(lastFragValidByteNum);

            // curValidByteNumReg    <= nextHasLessFrag ? 0 : fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
            curInvalidByteNumReg  <= nextHasLessFrag ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : 0;
            curInvalidBitNumReg   <= nextHasLessFrag ? fromInteger(valueOf(DATA_BUS_WIDTH)) : 0;
            // nextValidByteNumReg   <= lastFragValidByteNum;
            nextInvalidByteNumReg <= lastFragInvalidByteNum;
            nextInvalidBitNumReg  <= lastFragInvalidBitNum;

            case ({ pack(sgeMergedMetaData.isFirst), pack(sgeMergedMetaData.isLast) })
                2'b11, 2'b01: begin
                    stateReg <= MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE;
                end
                2'b10, 2'b00: begin
                    stateReg <= MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE;
                end
            endcase
            // $display(
            //     "time=%0t: preprocessNextSGL", $time,
            //     ", isOnlySGE=", fshow(isOnlySGE),
            //     ", hasLessFrag=", fshow(hasLessFrag),
            //     ", nextHasLessFrag=", fshow(nextHasLessFrag),
            //     ", sgeMergedMetaData.isFirst=", fshow(sgeMergedMetaData.isFirst),
            //     ", sgeMergedMetaData.isLast=", fshow(sgeMergedMetaData.isLast),
            //     ", lastFragValidByteNum=%0d", lastFragValidByteNum,
            //     ", lastFragValidBitNum=%0d", lastFragValidBitNum,
            //     ", lastFragInvalidByteNum=%0d", lastFragInvalidByteNum,
            //     ", lastFragInvalidBitNum=%0d", lastFragInvalidBitNum,
            //     // ", curValidByteNumReg=%0d", curValidByteNumReg,
            //     ", curInvalidByteNumReg=%0d", curInvalidByteNumReg,
            //     ", curInvalidBitNumReg=%0d", curInvalidBitNumReg,
            //     // ", nextValidByteNumReg=%0d", nextValidByteNumReg,
            //     ", nextInvalidByteNumReg=%0d", nextInvalidByteNumReg,
            //     ", nextInvalidBitNumReg=%0d", nextInvalidBitNumReg,
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
            //     ", nextPrePayloadFrag.isFirst=", fshow(nextPrePayloadFrag.isFirst),
            //     ", nextPrePayloadFrag.isLast=", fshow(nextPrePayloadFrag.isLast),
            //     ", nextPrePayloadFrag.byteEn=%h", nextPrePayloadFrag.byteEn
            // );
            return nextPrePayloadFrag;
        endactionvalue
    endfunction

    function Action preprocessNextSGE();
        action
            let sgeMergedMetaData = sgeMergedMetaDataPipeIn.first;
            sgeMergedMetaDataPipeIn.deq;

            // let isOnlySGE = sgeMergedMetaData.isFirst && sgeMergedMetaData.isLast;
            // sgeIsOnlyReg <= isOnlySGE;
            sgeIsLastReg <= sgeMergedMetaData.isLast;

            let lastFragValidByteNum = sgeMergedMetaData.lastFragValidByteNum;
            let {
                lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum
            } = calcFragBitNumAndByteNum(lastFragValidByteNum);

            // let sumValidByteNum   = nextValidByteNumReg   + lastFragValidByteNum;
            let sumInvalidByteNum = nextInvalidByteNumReg + lastFragInvalidByteNum;
            let sumInvalidBitNum  = nextInvalidBitNumReg  + lastFragInvalidBitNum;

            let hasLessFrag = nextInvalidByteNumReg >= lastFragValidByteNum;
            // let hasLessFrag = !sgeIsOnlyReg && (sumInvalidByteNum >= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)));
            hasLessFragReg <= hasLessFrag;

            // let curValidByteNum   = nextValidByteNumReg;
            let curInvalidByteNum = nextInvalidByteNumReg;
            let curInvalidBitNum  = nextInvalidBitNumReg;
            // curValidByteNumReg   <= curValidByteNum;
            curInvalidByteNumReg <= curInvalidByteNum;
            curInvalidBitNumReg  <= curInvalidBitNum;

            // let nextValidByteNum   = sumValidByteNum   & zeroExtend(busByteNumMask);
            let nextInvalidByteNum = sumInvalidByteNum & zeroExtend(busByteNumMask);
            let nextInvalidBitNum  = sumInvalidBitNum  & zeroExtend(busBitNumMask);
            // nextValidByteNumReg   <= nextValidByteNum;
            nextInvalidByteNumReg <= nextInvalidByteNum;
            nextInvalidBitNumReg  <= nextInvalidBitNum;

            case ({ pack(sgeMergedMetaData.isFirst), pack(sgeMergedMetaData.isLast) })
                2'b11, 2'b01: begin
                    stateReg <= MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE;
                end
                2'b10, 2'b00: begin
                    stateReg <= MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE;
                end
            endcase
            // $display(
            //     "time=%0t: preprocessNextSGE", $time,
            //     ", hasLessFrag=", fshow(hasLessFrag),
            //     ", sgeMergedMetaData.isFirst=", fshow(sgeMergedMetaData.isFirst),
            //     ", sgeMergedMetaData.isLast=", fshow(sgeMergedMetaData.isLast),
            //     ", lastFragValidByteNum=%0d", lastFragValidByteNum,
            //     ", lastFragValidBitNum=%0d", lastFragValidBitNum,
            //     ", lastFragInvalidByteNum=%0d", lastFragInvalidByteNum,
            //     ", lastFragInvalidBitNum=%0d", lastFragInvalidBitNum,
            //     // ", sumValidByteNum=%0d", sumValidByteNum,
            //     ", sumInvalidByteNum=%0d", sumInvalidByteNum,
            //     ", sumInvalidBitNum=%0d", sumInvalidBitNum,
            //     // ", curValidByteNum=%0d", curValidByteNum,
            //     ", curInvalidByteNum=%0d", curInvalidByteNum,
            //     ", curInvalidBitNum=%0d", curInvalidBitNum,
            //     // ", nextValidByteNum=%0d", nextValidByteNum,
            //     ", nextInvalidByteNum=%0d", nextInvalidByteNum,
            //     ", nextInvalidBitNum=%0d", nextInvalidBitNum
            // );
        endaction
    endfunction

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;

        stateReg <= MERGE_SGL_PAYLOAD_INIT;
    endrule

    rule init if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_INIT);
        let nextPayloadFrag <- preprocessNextSGL;
        prePayloadFragReg <= nextPayloadFrag;
    endrule

    rule mergeFirstOrMidSGE if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE);
        let curPayloadFrag = sgeMergedPayloadPipeIn.first;
        sgeMergedPayloadPipeIn.deq;

        let mergedFrag = mergeFragData(
            prePayloadFragReg, curPayloadFrag,
            curInvalidByteNumReg, curInvalidBitNumReg
        );
        // In case prePayloadFragReg is emptyDataStream,
        // then it should set mergeFrag.isFirst as true.
        mergedFrag.isFirst = isFirstFragReg;

        let shouldOutput = True;
        let nextPrePayloadFrag = mergedFrag;
        if (curPayloadFrag.isLast) begin
            preprocessNextSGE;

            if (hasLessFragReg) begin
                shouldOutput = False;
                nextPrePayloadFrag.byteEn = mergedFrag.byteEn >> nextInvalidByteNumReg;
                nextPrePayloadFrag.data   = mergedFrag.data   >> nextInvalidBitNumReg;
            end
        end
        prePayloadFragReg <= nextPrePayloadFrag;

        let outPayloadFrag = mergedFrag;
        // outPayloadFrag.isFirst = isFirstFragReg;
        outPayloadFrag.isLast = False;
        if (shouldOutput) begin
            isFirstFragReg <= False;

            pktPayloadOutQ.enq(outPayloadFrag);
        end
        // $display(
        //     "time=%0t: mergeFirstOrMidSGE", $time,
        //     ", shouldOutput=", fshow(shouldOutput),
        //     ", hasLessFragReg=", fshow(hasLessFragReg),
        //     ", curInvalidByteNumReg=%0d", curInvalidByteNumReg,
        //     ", curInvalidBitNumReg=%0d", curInvalidBitNumReg,
        //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
        //     ", mergedFrag.isFirst=", fshow(mergedFrag.isFirst),
        //     ", mergedFrag.isLast=", fshow(mergedFrag.isLast),
        //     ", mergedFrag.byteEn=%h", mergedFrag.byteEn,
        //     ", nextPrePayloadFrag.isFirst=", fshow(nextPrePayloadFrag.isFirst),
        //     ", nextPrePayloadFrag.isLast=", fshow(nextPrePayloadFrag.isLast),
        //     ", nextPrePayloadFrag.byteEn=%h", nextPrePayloadFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    rule mergeLastOrOnlySGE if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE);
        let nextPayloadFrag = emptyDataStream;
        let outPayloadFrag = prePayloadFragReg;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (sgeMergedMetaDataPipeIn.notEmpty && sgeMergedPayloadPipeIn.notEmpty) begin
                nextPayloadFrag <- preprocessNextSGL;
            end
            else begin
                // Wait for a SGE of next SGL, if no next SGE metadata or payload
                stateReg <= MERGE_SGL_PAYLOAD_INIT;
            end
        end
        else begin
            nextPayloadFrag = sgeMergedPayloadPipeIn.first;
            sgeMergedPayloadPipeIn.deq;

            nextPayloadFrag.isFirst = False;
            if (!sgeIsOnlyReg && hasLessFragReg && nextPayloadFrag.isLast) begin
                // Has one less fragment
                stateReg <= MERGE_SGL_PAYLOAD_INIT;
                isLastFrag = True;
            end
        end
        prePayloadFragReg <= nextPayloadFrag;

        outPayloadFrag = mergeFragData(
            prePayloadFragReg, nextPayloadFrag,
            curInvalidByteNumReg, curInvalidBitNumReg
        );
        outPayloadFrag.isLast = isLastFrag;
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: mergeLastOrOnlySGE", $time,
        //     ", sgeIsOnlyReg=", fshow(sgeIsOnlyReg),
        //     ", hasLessFragReg=", fshow(hasLessFragReg),
        //     ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
        //     ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
        //     ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
        //     ", nextPayloadFrag.isFirst=", fshow(nextPayloadFrag.isFirst),
        //     ", nextPayloadFrag.isLast=", fshow(nextPayloadFrag.isLast),
        //     ", nextPayloadFrag.byteEn=%h", nextPayloadFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule

interface PayloadSegment;
    interface PipeOut#(PktLen) pktLenPipeOut;
    interface DataStreamPipeOut pktPayloadPipeOut;
endinterface

typedef enum {
    ADJUST_PAYLOAD_SEGMENT_INIT,
    ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT,
    ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT
    // ADJUST_PAYLOAD_SEGMENT_FIRST_PKT,
    // ADJUST_PAYLOAD_SEGMENT_MID_PKT,
    // ADJUST_PAYLOAD_SEGMENT_LAST_PKT,
    // ADJUST_PAYLOAD_SEGMENT_ONLY_PKT,
    // ADJUST_PAYLOAD_SEGMENT_LAST_PKT_EXTRA_FRAG
} AdjustPayloadSegmentState deriving(Bits, Eq, FShow);

module mkAdjustPayloadSegment#(
    Bool clearAll,
    PipeOut#(AdjustedTotalPayloadMetaData) adjustedTotalPayloadMetaDataPipeIn,
    PipeOut#(DataStream) sglAllPayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(ByteEn) firstPktLastFragByteEnReg <- mkRegU;

    Reg#(ByteEnBitNum) firstPktLastFragValidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     firstPktLastFragValidBitNumReg <- mkRegU;
    // Reg#(ByteEnBitNum) firstPktLastFragInvalidByteNumReg <- mkRegU;
    // Reg#(BusBitNum)     firstPktLastFragInvalidBitNumReg <- mkRegU;
    // Reg#(ByteEnBitNum)  lastPktLastFragInvalidByteNumReg <- mkRegU;
    // Reg#(BusBitNum)      lastPktLastFragInvalidBitNumReg <- mkRegU;

    // Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(Bool) hasExtraFragReg <- mkRegU;
    Reg#(Bool) sglHasOnlyPktReg <- mkRegU;
    Reg#(Bool) sglHasOnlyFragOnlyPktReg <- mkRegU;

    // Reg#(PktLen) pmtuPktLenReg <- mkRegU;
    // Reg#(PktFragNum) lastPktFragNumReg <- mkRegU;
    Reg#(PktFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PktFragNum) pktRemainingFragNumReg <- mkRegU;
    Reg#(PktNum) sglRemainingPktNumReg <- mkRegU;
    Reg#(AdjustPayloadSegmentState) stateReg <- mkReg(ADJUST_PAYLOAD_SEGMENT_INIT);

    let emptyDataStream = DataStream {
        data: 0,
        byteEn: 0,
        isFirst: False,
        isLast: False
    };

    rule resetAndClear if (clearAll);
        // pktLenOutQ.clear;
        pktPayloadOutQ.clear;
        stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
    endrule

    function ActionValue#(DataStream) prepareNextSGL();
        actionvalue
            let adjustedTotalPayloadMeta = adjustedTotalPayloadMetaDataPipeIn.first;
            adjustedTotalPayloadMetaDataPipeIn.deq;

            // pmtuPktLenReg <= calcPmtuLen(adjustedTotalPayloadMeta.pmtu);
            pmtuFragNumReg <= calcFragNumByPMTU(adjustedTotalPayloadMeta.pmtu);

            pktRemainingFragNumReg <= adjustedTotalPayloadMeta.firstPktFragNum;
            sglRemainingPktNumReg <= adjustedTotalPayloadMeta.adjustedPktNum;
            // lastPktFragNumReg <= adjustedTotalPayloadMeta.lastPktFragNum;

            let origLastFragValidByteNum     = adjustedTotalPayloadMeta.origLastFragValidByteNum;
            let firstPktLastFragValidByteNum = adjustedTotalPayloadMeta.firstPktLastFragValidByteNum;
            // let lastPktLastFragValidByteNum  = adjustedTotalPayloadMeta.lastPktLastFragValidByteNum;
            let {
                firstPktLastFragValidBitNum,
                firstPktLastFragInvalidByteNum,
                firstPktLastFragInvalidBitNum
            } = calcFragBitNumAndByteNum(firstPktLastFragValidByteNum);

            firstPktLastFragValidByteNumReg <= firstPktLastFragValidByteNum;
            firstPktLastFragValidBitNumReg  <= firstPktLastFragValidBitNum;
            // firstPktLastFragInvalidByteNumReg <= firstPktLastFragInvalidByteNum;
            // firstPktLastFragInvalidBitNumReg <= firstPktLastFragInvalidBitNum;
            firstPktLastFragByteEnReg <= genByteEn(firstPktLastFragValidByteNum);

            // let {
            //     lastPktLastFragValidBitNum,
            //     lastPktLastFragInvalidByteNum,
            //     lastPktLastFragInvalidBitNum
            // } = calcFragBitNumAndByteNum(lastPktLastFragValidByteNum);
            // lastPktLastFragInvalidByteNumReg <= lastPktLastFragInvalidByteNum;
            // lastPktLastFragInvalidBitNumReg <= lastPktLastFragInvalidBitNum;
            let sglHasOnlyPkt = isOneR(adjustedTotalPayloadMeta.adjustedPktNum);
            sglHasOnlyPktReg <= sglHasOnlyPkt;
            let hasExtraFrag = firstPktLastFragValidByteNum < origLastFragValidByteNum;
            // let hasExtraFrag = (
            //     { 1'b0, firstPktLastFragInvalidByteNum } +
            //     { 1'b0, origLastFragValidByteNum }
            // ) > fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
            hasExtraFragReg <= hasExtraFrag;

            if (sglHasOnlyPkt) begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end

            let curPayloadFrag = sglAllPayloadPipeIn.first;
            sglAllPayloadPipeIn.deq;

            let isOrigOnlyPkt = isOneR(adjustedTotalPayloadMeta.origPktNum);
            let sglHasOnlyFragOnlyPkt = isOrigOnlyPkt && curPayloadFrag.isLast;
            sglHasOnlyFragOnlyPktReg <= sglHasOnlyFragOnlyPkt;

            // isFirstFragReg <= True;
            isFirstPktReg  <= True;
            // $display(
            //     "time=%0t: prepareNextSGL", $time,
            //     ", sglHasOnlyPkt=", fshow(sglHasOnlyPkt),
            //     ", hasExtraFrag=", fshow(hasExtraFrag),
            //     ", hasExtraFragReg=", fshow(hasExtraFragReg),
            //     // ", sgeMergedMetaData.isFirst=", fshow(sgeMergedMetaData.isFirst),
            //     // ", sgeMergedMetaData.isLast=", fshow(sgeMergedMetaData.isLast),
            //     ", firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
            //     ", firstPktLastFragValidBitNum=%0d", firstPktLastFragValidBitNum,
            //     ", firstPktLastFragInvalidByteNum=%0d", firstPktLastFragInvalidByteNum,
            //     ", firstPktLastFragInvalidBitNum=%0d", firstPktLastFragInvalidBitNum,
            //     // ", lastPktLastFragValidByteNum=%0d", lastPktLastFragValidByteNum,
            //     ", adjustedTotalPayloadMeta.pktNum=%0d", adjustedTotalPayloadMeta.adjustedPktNum,
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn
            //     // ", nextPrePayloadFrag.isFirst=", fshow(nextPrePayloadFrag.isFirst),
            //     // ", nextPrePayloadFrag.isLast=", fshow(nextPrePayloadFrag.isLast),
            //     // ", nextPrePayloadFrag.byteEn=%h", nextPrePayloadFrag.byteEn
            // );
            return curPayloadFrag;
        endactionvalue
    endfunction

    rule init if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_INIT);
        let nextPrePayloadFrag <- prepareNextSGL;
        prePayloadFragReg <= nextPrePayloadFrag;
    endrule

    rule adjustFirstOrMidPkt if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT);
        let isLastFrag = isOneR(pktRemainingFragNumReg);
        let outPayloadFrag = prePayloadFragReg;

        if (!sglHasOnlyFragOnlyPktReg) begin
            let curPayloadFrag  = sglAllPayloadPipeIn.first;
            let nextPayloadFrag = curPayloadFrag;

            let mergedFrag = mergeFragData(
                prePayloadFragReg, curPayloadFrag,
                firstPktLastFragValidByteNumReg, firstPktLastFragValidBitNumReg
            );

            if (!isFirstPktReg) begin
                outPayloadFrag = mergedFrag;
            end

            if (!(isFirstPktReg && isLastFrag)) begin
                sglAllPayloadPipeIn.deq;
            end
            else begin
                // Do not dequeue when the last fragment of the first packet,
                // Since the queue head is the first fragment of the next packet,
                // So keep the last fragment of the first packet in prePayloadFragReg.
                nextPayloadFrag = prePayloadFragReg;
            end
            nextPayloadFrag.isFirst = isLastFrag;
            prePayloadFragReg <= nextPayloadFrag;
        end

        if (isLastFrag) begin
            if (isFirstPktReg) begin
                outPayloadFrag.byteEn = firstPktLastFragByteEnReg;
                isFirstPktReg <= False;
            end

            // isFirstFragReg <= True;
            sglRemainingPktNumReg <= sglRemainingPktNumReg - 1;

            if (isTwoR(sglRemainingPktNumReg)) begin
                // pktRemainingFragNumReg <= lastPktFragNumReg;
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                pktRemainingFragNumReg <= pmtuFragNumReg;
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end
        end
        else begin
            // isFirstFragReg <= False;
            pktRemainingFragNumReg <= pktRemainingFragNumReg - 1;
        end

        // outPayloadFrag.isFirst = isFirstFragReg;
        outPayloadFrag.isLast  = isLastFrag;
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: adjustFirstOrMidPkt", $time,
        //     ", sglHasOnlyFragOnlyPktReg=", fshow(sglHasOnlyFragOnlyPktReg),
        //     // ", isFirstFragReg=", fshow(isFirstFragReg),
        //     ", hasExtraFragReg=", fshow(hasExtraFragReg),
        //     ", isLastFrag=", fshow(isLastFrag),
        //     ", pktRemainingFragNumReg=%0d", pktRemainingFragNumReg,
        //     ", sglRemainingPktNumReg=%0d", sglRemainingPktNumReg,
        //     ", firstPktLastFragValidByteNumReg=%0d", firstPktLastFragValidByteNumReg,
        //     ", firstPktLastFragValidBitNumReg=%0d", firstPktLastFragValidBitNumReg,
        //     ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
        //     ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
        //     ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
        //     // ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     // ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     // ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
        //     // ", mergedFrag.isFirst=", fshow(mergedFrag.isFirst),
        //     // ", mergedFrag.isLast=", fshow(mergedFrag.isLast),
        //     // ", mergedFrag.byteEn=%h", mergedFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    rule adjustLastOrOnlyPkt if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT);
        let nextPayloadFrag = emptyDataStream;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (adjustedTotalPayloadMetaDataPipeIn.notEmpty && sglAllPayloadPipeIn.notEmpty) begin
                nextPayloadFrag <- prepareNextSGL;
            end
            else begin
                // Wait for a packet of next SGE, if no next SGE packet metadata or payload
                stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
            end
        end
        else begin
            nextPayloadFrag = sglAllPayloadPipeIn.first;
            sglAllPayloadPipeIn.deq;

            // nextPayloadFrag.isFirst = False;
            if (!sglHasOnlyPktReg && !hasExtraFragReg && nextPayloadFrag.isLast) begin
                // No extra fragment
                stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
                isLastFrag = True;
            end
        end

        let mergedFrag = mergeFragData(
            prePayloadFragReg, nextPayloadFrag,
            firstPktLastFragValidByteNumReg, firstPktLastFragValidBitNumReg
        );
        prePayloadFragReg <= nextPayloadFrag;

        immAssert(
            isOne(sglRemainingPktNumReg),
            "sglRemainingPktNumReg assertion @ mkAdjustPayloadSegment",
            $format(
                "sglRemainingPktNumReg=%0d", fshow(sglRemainingPktNumReg),
                " should be one when stateReg=", fshow(stateReg)
            )
        );

        let outPayloadFrag = prePayloadFragReg;
        if (!sglHasOnlyPktReg) begin
            // isFirstFragReg <= False;
            // outPayloadFrag.isFirst = isFirstFragReg;
            outPayloadFrag = mergedFrag;
            outPayloadFrag.isLast  = isLastFrag;
        end
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: adjustLastOrOnlyPkt", $time,
        //     ", sglHasOnlyPktReg=", fshow(sglHasOnlyPktReg),
        //     ", hasExtraFragReg=", fshow(hasExtraFragReg),
        //     ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
        //     ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
        //     ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
        //     ", nextPayloadFrag.isFirst=", fshow(nextPayloadFrag.isFirst),
        //     ", nextPayloadFrag.isLast=", fshow(nextPayloadFrag.isLast),
        //     ", nextPayloadFrag.byteEn=%h", nextPayloadFrag.byteEn,
        //     ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule

interface BramPipe#(type anytype);
    interface PipeOut#(anytype) pipeOut;
    method Action clear();
    method Bool notEmpty();
endinterface

module mkConnectBramQ2PipeOut#(FIFOF#(anytype) bramQ)(
    BramPipe#(anytype)
) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(postBramQ), toGet(bramQ));

    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

module mkConnectPipeOut2BramQ#(
    PipeOut#(anytype) pipeIn, FIFOF#(anytype) bramQ
)(BramPipe#(anytype)) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(bramQ), toGet(pipeIn));
    mkConnection(toPut(postBramQ), toGet(bramQ));

    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

typedef struct {
    WorkQueueElem wqe;
    // DmaReadMetaDataSGL sglDmaReadMetaData;
    // PMTU               pmtu;
    // ADDR               raddr;
    // Bool               segment;
    // Bool               addPadding;
} PayloadGenReqSG deriving(Bits, FShow);

typedef struct {
    // Bool segment;
    // Bool addPadding;
    Bool isRespErr;
} PayloadGenRespSG deriving(Bits, FShow);

interface PayloadGenerator;
    interface Server#(PayloadGenReqSG, PayloadGenRespSG) srvPort;
    interface DataStreamPipeOut payloadDataStreamPipeOut;
    method Bool payloadNotEmpty();
endinterface

module mkPayloadGenerator#(
    Bool clearAll, DmaReadCntrl dmaReadCntrl
)(PayloadGenerator);
    FIFOF#(PayloadGenReqSG)   payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadGenRespSG) payloadGenRespQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple2#(PayloadGenReqSG, Bool)) adjustReqPktLenQ <- mkFIFOF;
    FIFOF#(Tuple8#(PayloadGenReqSG, Length, PktNum, ResiduePMTU, PMTU, PktLen, PktNum, Bool)) adjustedFirstAndLastPktLenQ <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadGenReqSG, AdjustedTotalPayloadMetaData)) adjustedTotalPayloadMetaDataQ <- mkFIFOF;
    // FIFOF#(Tuple3#(PayloadGenReqSG, ByteEn, PktFragNum)) pendingGenReqQ <- mkFIFOF;
    // FIFOF#(Tuple3#(Bool, Bool, PktFragNum)) pendingGenRespQ <- mkFIFOF;
    // FIFOF#(Tuple3#(DataStream, Bool, Bool)) payloadSegmentQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let bramQ2PipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);
    let payloadBufPipeOut = bramQ2PipeOut.pipeOut;
    // let payloadBufPipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);

    Reg#(PktFragNum) pmtuFragCntReg <- mkRegU;
    Reg#(Bool)    shouldSetFirstReg <- mkReg(False);
    Reg#(Bool)     isFragCntZeroReg <- mkReg(False);
    Reg#(Bool)     isNormalStateReg <- mkReg(True);

    rule resetAndClear if (clearAll);
        payloadGenReqQ.clear;
        payloadGenRespQ.clear;

        adjustReqPktLenQ.clear;
        adjustedFirstAndLastPktLenQ.clear;
        adjustedTotalPayloadMetaDataQ.clear;
        // pendingGenReqQ.clear;
        // pendingGenRespQ.clear;
        // payloadSegmentQ.clear;
        payloadBufQ.clear;

        bramQ2PipeOut.clear;

        shouldSetFirstReg <= False;
        isFragCntZeroReg  <= False;
        isNormalStateReg  <= True;

        // $display(
        //     "time=%0t: reset and clear mkPayloadGenerator", $time,
        //     ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty)
        // );
    endrule

    // rule debugNotFull if (!(
    //     payloadGenRespQ.notFull &&
    //     pendingGenReqQ.notFull  &&
    //     // pendingGenRespQ.notFull &&
    //     // payloadSegmentQ.notFull &&
    //     payloadBufQ.notFull
    // ));
    //     $display(
    //         "time=%0t: mkPayloadGenerator debugNotFull", $time,
    //         ", qpn=%h", cntrlStatus.comm.getSQPN,
    //         ", isSQ=", fshow(cntrlStatus.isSQ),
    //         ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
    //         ", payloadGenRespQ.notFull=", fshow(payloadGenRespQ.notFull),
    //         ", pendingGenReqQ.notFull=", fshow(pendingGenReqQ.notFull),
    //         // ", pendingGenRespQ.notFull=", fshow(pendingGenRespQ.notFull),
    //         // ", payloadSegmentQ.notFull=", fshow(payloadSegmentQ.notFull),
    //         ", payloadBufQ.notFull=", fshow(payloadBufQ.notFull)
    //     );
    // endrule

    // rule debugNotEmpty if (!(
    //     payloadGenRespQ.notEmpty &&
    //     pendingGenReqQ.notEmpty  &&
    //     // pendingGenRespQ.notEmpty &&
    //     // payloadSegmentQ.notEmpty &&
    //     payloadBufQ.notEmpty
    // ));
    //     $display(
    //         "time=%0t: mkPayloadGenerator debugNotEmpty", $time,
    //         ", qpn=%h", cntrlStatus.comm.getSQPN,
    //         ", isSQ=", fshow(cntrlStatus.isSQ),
    //         ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
    //         ", payloadGenRespQ.notEmpty=", fshow(payloadGenRespQ.notEmpty),
    //         ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty),
    //         // ", pendingGenRespQ.notEmpty=", fshow(pendingGenRespQ.notEmpty),
    //         // ", payloadSegmentQ.notEmpty=", fshow(payloadSegmentQ.notEmpty),
    //         ", payloadBufQ.notEmpty=", fshow(payloadBufQ.notEmpty)
    //     );
    // endrule

    rule recvReq if (!clearAll);
        let payloadGenReq = payloadGenReqQ.first;
        payloadGenReqQ.deq;

        let wqe = payloadGenReq.wqe;
        let sglIdx = 0;
        let sge = wqe.sgl[sglIdx];
        // If first SGE has zero length, then whole WQE has no payload
        let isZeroPayloadLen = isZeroR(sge.len);
        if (isZeroPayloadLen) begin
            immAssert(
                sge.isLast,
                "last SGE assertion @ mkDmaReadCntrl",
                $format(
                    "sge.isLast=", fshow(sge.isLast),
                    " should be true when sglIdx=%d", sglIdx,
                    ", and sge.len=%d", sge.len
                )
            );
        end

        if (!isZeroPayloadLen) begin
            let dmaReadCntrlReq = DmaReadCntrlReq {
                sglDmaReadMetaData: DmaReadMetaDataSGL {
                    sgl           : wqe.sgl,
                    sqpn          : wqe.sqpn,
                    wrID          : wqe.id
                },
                pmtu              : wqe.pmtu
            };
            dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);
        end
        adjustReqPktLenQ.enq(tuple2(payloadGenReq, isZeroPayloadLen));
        $display(
            "time=%0t: mkPayloadGenerator recvReq", $time,
            ", payloadGenReq=", fshow(payloadGenReq)
        );
    endrule

    rule adjustFirstAndLastPktLen if (!clearAll);
        let { payloadGenReq, isZeroPayloadLen } = adjustReqPktLenQ.first;
        adjustReqPktLenQ.deq;
        let wqe = payloadGenReq.wqe;

        let totalLen = 0;
        if (!isZeroPayloadLen) begin
            let sglTotalPayloadLenMetaData = dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut.first;
            dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut.deq;
            totalLen = sglTotalPayloadLenMetaData.totalLen;
        end

        let { truncatedPktNum, residue } = truncateLenByPMTU(totalLen, wqe.pmtu);
        let {
            pmtuLen, firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr //, isSinglePkt
        } = calcPktNumAndPktLenByAddrAndPMTU(
            wqe.raddr, totalLen, wqe.pmtu
        );

        adjustedFirstAndLastPktLenQ.enq(tuple8(
            payloadGenReq, totalLen, truncatedPktNum, residue,
            wqe.pmtu, firstPktLen, totalPktNum, isZeroPayloadLen
        ));
        $display(
            "time=%0t: mkPayloadGenerator adjustFirstAndLastPktLen", $time,
            ", payloadGenReq=", fshow(payloadGenReq)
        );
    endrule

    rule calcDetailTotalPayloadMetaData if (!clearAll);
        let {
            payloadGenReq, totalLen, truncatedPktNum, residue,
            pmtu, firstPktLen, totalPktNum, isZeroPayloadLen
        } = adjustedFirstAndLastPktLenQ.first;
        adjustedFirstAndLastPktLenQ.deq;

        let origLastFragValidByteNum     = calcLastFragValidByteNum(totalLen);
        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(firstPktLen);
        // let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(lastPktLen);
        let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        // let lastPktFragNum  = calcFragNumByPktLen(lastPktLen);
        // let firstPktPadCnt  = calcPadCnt(firstPktLen);
        // let lastPktPadCnt   = calcPadCnt(lastPktLen);
        let origPktNum = truncatedPktNum + (isZeroR(residue) ? 0 : 1);

        let adjustedTotalPayloadMetaData = AdjustedTotalPayloadMetaData {
            firstPktLen                  : firstPktLen,
            firstPktFragNum              : firstPktFragNum,
            firstPktLastFragValidByteNum : firstPktLastFragValidByteNum,
            // firstPktPadCnt               : firstPktPadCnt,
            // lastPktLen                   : lastPktLen,
            // lastPktFragNum               : lastPktFragNum,
            // lastPktLastFragValidByteNum  : lastPktLastFragValidByteNum,
            // lastPktPadCnt                : lastPktPadCnt,
            origLastFragValidByteNum     : origLastFragValidByteNum,
            adjustedPktNum               : totalPktNum,
            origPktNum                   : origPktNum,
            pmtu                         : pmtu
            // totalLen                     : totalLen
        };
        if (!isZeroPayloadLen) begin
            adjustedTotalPayloadMetaDataQ.enq(tuple2(
                payloadGenReq, adjustedTotalPayloadMetaData
            ));
        end
        $display(
            "time=%0t: mkPayloadGenerator calcDetailTotalPayloadMetaData", $time,
            ", payloadGenReq=", fshow(payloadGenReq)
        );
    endrule

    interface srvPort = toGPServer(payloadGenReqQ, payloadGenRespQ);
    interface payloadDataStreamPipeOut = payloadBufPipeOut;
    method Bool payloadNotEmpty() = bramQ2PipeOut.notEmpty;
endmodule
