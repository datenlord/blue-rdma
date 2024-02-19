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
typedef Bit#(48)  MAC;

typedef union tagged {
    AddrIPv4 IPv4;
    AddrIPv6 IPv6;
} IP deriving(Bits, Bounded);

instance FShow#(IP);
    function Fmt fshow(IP ipAddr);
        case (ipAddr) matches
            tagged IPv4 .ipv4: begin
                return $format(
                    "ipv4=%0d.%0d.%0d.%0d",
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
    IMM  Imm;
    RKEY RKey;
} ImmOrRKey deriving(Bits, FShow);

typedef struct {
    WorkReqID id; // TODO: remove it
    WorkReqOpCode opcode;
    FlagsType#(WorkReqSendFlag) flags;
    TypeQP qpType;
    PSN psn;
    PMTU pmtu;
    IP dqpIP;
    MAC macAddr;
    ScatterGatherList sgl;
    Length totalLen;
    ADDR raddr;
    RKEY rkey;
    QPN sqpn; // TODO: remove it
    QPN dqpn;
    Maybe#(Long) comp;
    Maybe#(Long) swap;
    Maybe#(ImmOrRKey) immDtOrInvRKey;
    Maybe#(QPN) srqn; // for XRC
    Maybe#(QKEY) qkey; // for UD
    Bool isFirst;
    Bool isLast;
} WorkQueueElem deriving(Bits);

instance FShow#(WorkQueueElem);
    function Fmt fshow(WorkQueueElem wqe);
        return $format(
            "WorkQueueElem { opcode=", fshow(wqe.opcode),
            ", flags=", fshow(wqe.flags),
            ", qpType=", fshow(wqe.qpType),
            ", psn=%h", wqe.psn,
            ", pmtu=", fshow(wqe.pmtu),
            ", dqpIP=", fshow(wqe.dqpIP),
            ", macAddr=%h", wqe.macAddr,
            ", sgl=", fshow(wqe.sgl),
            ", totalLen=%0d", wqe.totalLen,
            ", rkey=%h", wqe.rkey,
            ", raddr=%h", wqe.raddr,
            ", sqpn=%h", wqe.sqpn,
            ", dqpn=%h", wqe.dqpn,
            ", comp=", fshow(wqe.comp),
            ", swap=", fshow(wqe.swap),
            ", immDtOrInvRKey=", fshow(wqe.immDtOrInvRKey),
            ", srqn=", fshow(wqe.srqn),
            ", qkey=", fshow(wqe.qkey),
            ", isFirst=", fshow(wqe.isFirst),
            ", isLast=", fshow(wqe.isLast), " }"
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

typedef struct {
    PktLen firstPktLen;
    PktLen lastPktLen;
    PktNum sgePktNum;
    PMTU   pmtu;
} PktMetaDataSGE deriving(Bits, FShow);

typedef struct {
    ByteEnBitNum lastFragValidByteNum;
    Bool         isFirst;
    Bool         isLast;
} MergedMetaDataSGE deriving(Bits, FShow);

// typedef struct {
//     QPN       sqpn; // TODO: remove it
//     WorkReqID wrID; // TODO: remove it
//     Length    totalLen;
//     PMTU      pmtu;
// } TotalPayloadLenMetaDataSGL deriving(Bits, FShow);

typedef struct {
    PktLen       firstPktLen;
    PktFragNum   firstPktFragNum;
    ByteEnBitNum firstPktLastFragValidByteNum;
    ByteEnBitNum origLastFragValidByteNum;
    PktNum       adjustedPktNum;
    PktNum       origPktNum;
    PMTU         pmtu;
} AdjustedTotalPayloadMetaData deriving(Bits, FShow);

typedef struct {
    ScatterGatherList sgl;
    Length totalLen;
    QPN sqpn; // TODO: remove it
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

function Tuple7#(PktLen, PktLen, PktLen, PktLen, PktLen, PktNum, ADDR) stepOneCalcPktNumAndPktLenByAddrAndPMTU(
    ADDR startAddr, Length len, PMTU pmtu
);
    let pmtuAlignedStartAddr = alignAddrByPMTU(startAddr, pmtu);
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
    let addrAndLenLowPartSum = addrLowPart + lenLowPart;

    return tuple7(
        pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart,
        maxFirstPktLen, truncatedPktNum, pmtuAlignedStartAddr
    );
endfunction

function Tuple4#(PktLen, PktLen, PktNum, ADDR) stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
    PktLen pmtuMask, PktLen addrAndLenLowPartSum, PktLen pmtuLen, PktLen lenLowPart,
    PktLen maxFirstPktLen, PktNum truncatedPktNum, ADDR pmtuAlignedStartAddr, PMTU pmtu
);
    let oneAsPSN = 1;
    let secondChunkStartAddr = addrAddPsnMultiplyPMTU(pmtuAlignedStartAddr, oneAsPSN, pmtu);

    ResiduePMTU residue  = truncateByPMTU(addrAndLenLowPartSum, pmtu);
    PktLen tmpLastPktLen = zeroExtend(residue);

    let pmtuInvMask   = ~pmtuMask;
    let noResidue     = isZeroR(pmtuMask & addrAndLenLowPartSum);
    let noExtraPkt    = isZeroR(pmtuInvMask & addrAndLenLowPartSum);
    let hasResidue    = !noResidue;
    let hasExtraPkt   = !noExtraPkt;
    let residuePktNum = pack(hasResidue);
    let extraPktNum   = pack(hasExtraPkt);
    let notFullPkt    = isZeroR(truncatedPktNum);
    // let residuePktNum = |(pmtuMask & addrAndLenLowPartSum);
    // let extraPktNum = |(pmtuInvMask & addrAndLenLowPartSum);
    // Bool hasResidue = unpack(residuePktNum);
    // Bool hasExtraPkt = unpack(extraPktNum);

    let totalPktNum = truncatedPktNum + zeroExtend(residuePktNum) + zeroExtend(extraPktNum);
    let firstPktLen = (notFullPkt && !hasExtraPkt) ? lenLowPart : maxFirstPktLen;
    let lastPktLen  = notFullPkt ? (hasExtraPkt ? tmpLastPktLen : lenLowPart) : (hasResidue ? tmpLastPktLen : pmtuLen);
    // let isSinglePkt = isLessOrEqOneR(totalPktNum);

    return tuple4(firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr);
endfunction

function PktFragNum calcFragNumByPktLen(PktLen pktLen) provisos(
    Add#(PMTU_FRAG_NUM_WIDTH, DATA_BUS_BYTE_NUM_WIDTH, PKT_LEN_WIDTH)
);
    BusByteWidthMask lastFragByteNumResidue = truncate(pktLen);
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

// the output DataStream keeps isFirst and isLast from preFrag
function DataStream mergeFragData(
    DataStream preFrag,
    DataStream curFrag,
    ByteEnBitNum preFragInvalidByteNum,
    BusBitNum preFragInvalidBitNum
);
    let resultFrag    = preFrag;
    resultFrag.byteEn = truncateLSB({ preFrag.byteEn, curFrag.byteEn } << preFragInvalidByteNum);
    resultFrag.data   = truncateLSB({ preFrag.data, curFrag.data } << preFragInvalidBitNum);
    return resultFrag;
endfunction

function DataStream genEmptyDataStream();
    return DataStream {
        data: 0,
        byteEn: 0,
        isFirst: False,
        isLast: False
    };
endfunction

interface AddrChunkSrv;
    interface Server#(AddrChunkReq, AddrChunkResp) srvPort;
    interface PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeOut;
    method Bool isIdle();
endinterface

typedef struct {
    PktNum remainingPktNum;
    PktLen firstPktLen;
    PktLen pmtuLen;
    PktLen lastPktLen;
    PMTU   pmtu;
    ADDR   startAddr;
    ADDR   nextAddr;
    Bool   isOrigFirst;
    Bool   isOrigLast;
} ChunkMetaData deriving(Bits);

module mkAddrChunkSrv#(Bool clearAll)(AddrChunkSrv);
    FIFOF#(AddrChunkReq)   reqQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(AddrChunkResp) respQ <- mkFIFOF;
    FIFOF#(PktMetaDataSGE) sgePktMetaDataOutQ <- mkFIFOF;

    // Pipeline FIFOF
    FIFOF#(Tuple8#(
        PktLen, PktLen, PktLen, PktLen, PktLen, PktNum, ADDR, AddrChunkReq
    )) calcMetaDataQ <- mkFIFOF;
    FIFOF#(ChunkMetaData) chunkMetaDataQ <- mkFIFOF;

    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(ADDR)     nextChunkAddrReg <- mkRegU;
    Reg#(Bool)      isFirstChunkReg <- mkReg(True);

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        sgePktMetaDataOutQ.clear;

        calcMetaDataQ.clear;
        chunkMetaDataQ.clear;

        isFirstChunkReg <= True;
    endrule

    rule recvReq if (!clearAll);
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
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart,
            maxFirstPktLen, truncatedPktNum, pmtuAlignedStartAddr
        } = stepOneCalcPktNumAndPktLenByAddrAndPMTU(
            addrChunkReq.startAddr, addrChunkReq.len, addrChunkReq.pmtu
        );

        calcMetaDataQ.enq(tuple8(
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, addrChunkReq
        ));
    endrule

    rule genChunkMetaData if (!clearAll);
        let {
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, addrChunkReq
        } = calcMetaDataQ.first;
        calcMetaDataQ.deq;

        let {
            firstPktLen, lastPktLen, sgePktNum, secondChunkStartAddr
        } = stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, addrChunkReq.pmtu
        );

        let chunkMetaData = ChunkMetaData {
            remainingPktNum: sgePktNum - 1,
            firstPktLen    : firstPktLen,
            pmtuLen        : pmtuLen,
            lastPktLen     : lastPktLen,
            pmtu           : addrChunkReq.pmtu,
            startAddr      : addrChunkReq.startAddr,
            nextAddr       : secondChunkStartAddr,
            isOrigFirst    : addrChunkReq.isFirst,
            isOrigLast     : addrChunkReq.isLast
        };
        chunkMetaDataQ.enq(chunkMetaData);

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

    rule genResp if (!clearAll);
        let chunkMetaData = chunkMetaDataQ.first;

        let firstPktLen = chunkMetaData.firstPktLen;
        let pmtuLen     = chunkMetaData.pmtuLen;
        let lastPktLen  = chunkMetaData.lastPktLen;
        let pmtu        = chunkMetaData.pmtu;
        let startAddr   = chunkMetaData.startAddr;
        let nextAddr    = chunkMetaData.nextAddr;
        let isOrigFirst = chunkMetaData.isOrigFirst;
        let isOrigLast  = chunkMetaData.isOrigLast;

        let oneAsPSN = 1;
        let nextChunkAddr   = addrAddPsnMultiplyPMTU(nextChunkAddrReg, oneAsPSN, pmtu);
        let remainingPktNum = remainingPktNumReg;
        if (isFirstChunkReg) begin
            nextChunkAddr   = nextAddr;
            remainingPktNum = chunkMetaData.remainingPktNum;
        end

        let isLastChunk = isZeroR(remainingPktNum);
        if (isLastChunk) begin
            chunkMetaDataQ.deq;
        end
        else begin
            remainingPktNumReg <= remainingPktNum - 1;
        end
        isFirstChunkReg  <= isLastChunk;
        nextChunkAddrReg <= nextChunkAddr;

        let chunkAddr = isFirstChunkReg ? startAddr : nextChunkAddrReg;
        let chunkLen  = isFirstChunkReg ? firstPktLen : (isLastChunk ? lastPktLen : pmtuLen);
        let addrChunkResp = AddrChunkResp {
            chunkAddr  : chunkAddr,
            chunkLen   : chunkLen,
            isFirst    : isFirstChunkReg,
            isLast     : isLastChunk,
            isOrigFirst: isOrigFirst,
            isOrigLast : isOrigLast
        };
        respQ.enq(addrChunkResp);

        // $display(
        //     "time=%0t: mkAddrChunkSrv genResp", $time,
        //     ", remainingPktNumReg=%0d", remainingPktNumReg,
        //     ", chunkAddr=%h", chunkAddr,
        //     ", nextChunkAddr=%h", nextChunkAddr,
        //     ", addrChunkResp=", fshow(addrChunkResp)
        // );
    endrule

    interface srvPort = toGPServer(reqQ, respQ);
    interface sgePktMetaDataPipeOut = toPipeOut(sgePktMetaDataOutQ);
    method Bool isIdle() = !(
        reqQ.notEmpty           ||
        respQ.notEmpty          ||
        chunkMetaDataQ.notEmpty ||
        sgePktMetaDataOutQ.notEmpty
    );
endmodule

typedef struct {
    DmaReadMetaDataSGL sglDmaReadMetaData;
    PMTU               pmtu;
} DmaReadCntrlReq deriving(Bits, FShow);

typedef struct {
    DmaReadResp dmaReadResp;
    Bool        isFirstFragInSGL;
    Bool        isLastFragInSGL;
} DmaReadCntrlResp deriving(Bits, FShow);

typedef Server#(DmaReadCntrlReq, DmaReadCntrlResp) DmaCntrlReadSrv;
typedef Client#(DmaReadCntrlReq, DmaReadCntrlResp) DmaCntrlReadClt;

interface DmaCntrl;
    method Bool isIdle();
    method Action cancel();
endinterface

interface DmaReadCntrl;
    interface DmaCntrlReadSrv srvPort;
    interface DmaCntrl dmaCntrl;
    interface PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeOut;
    // interface PipeOut#(TotalPayloadLenMetaDataSGL) sglTotalPayloadLenMetaDataPipeOut;
    interface PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeOut;
endinterface

module mkDmaReadCntrl#(
    Bool clearAll, DmaReadSrv dmaReadSrv
)(DmaReadCntrl);
    FIFOF#(DmaReadCntrlReq)   reqQ <- mkFIFOF;
    FIFOF#(DmaReadCntrlResp) respQ <- mkFIFOF;
    FIFOF#(MergedMetaDataSGE) sgeMergedMetaDataOutQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    // FIFOF#(TotalPayloadLenMetaDataSGL) sglTotalPayloadLenMetaDataOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple2#(ScatterGatherElem, PMTU)) pendingScatterGatherElemQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(LKEY) pendingLKeyQ <- mkFIFOF;
    FIFOF#(Tuple2#(QPN, WorkReqID)) pendingDmaCntrlReqQ <- mkFIFOF; // TODO: remove it
    FIFOF#(Tuple2#(Bool, Bool))     pendingDmaReadReqQ <- mkFIFOF;

    let addrChunkSrv <- mkAddrChunkSrv(clearAll);

    Reg#(Bool) gracefulStopReg[2] <- mkCReg(2, False);
    Reg#(Bool)       cancelReg[2] <- mkCReg(2, False);

    Reg#(Length) totalLenReg <- mkRegU;
    Reg#(NumSGE)   sgeNumReg <- mkRegU;
    Reg#(IdxSGL)   sglIdxReg <- mkReg(0);

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        sgeMergedMetaDataOutQ.clear;
        // sglTotalPayloadLenMetaDataOutQ.clear;

        pendingScatterGatherElemQ.clear;
        pendingLKeyQ.clear;
        pendingDmaCntrlReqQ.clear;
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
                "sge.len=%0d", sge.len,
                " should not be zero when sglIdxReg=%0d", sglIdxReg
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

        if (isZeroR(sglIdxReg)) begin
            immAssert(
                sge.isFirst,
                "first SGE assertion @ mkDmaReadCntrl",
                $format(
                    "sge.isFirst=", fshow(sge.isFirst),
                    " should be true when sglIdxReg=%0d", sglIdxReg
                )
            );
        end
        if (isAllOnesR(sglIdxReg)) begin
            immAssert(
                sge.isLast,
                "last SGE assertion @ mkDmaReadCntrl",
                $format(
                    "sge.isLast=", fshow(sge.isLast),
                    " should be true when sglIdxReg=%0d", sglIdxReg
                )
            );
        end

        if (sge.isLast) begin
            reqQ.deq;
            sglIdxReg <= 0;

            // let sglTotalPayloadLenMetaData = TotalPayloadLenMetaDataSGL {
            //     sqpn    : curSQPN,
            //     wrID    : curWorkReqID,
            //     totalLen: totalLen,
            //     pmtu    : dmaReadCntrlReq.pmtu
            // };
            // sglTotalPayloadLenMetaDataOutQ.enq(sglTotalPayloadLenMetaData);
            immAssert(
                totalLen == dmaReadCntrlReq.sglDmaReadMetaData.totalLen,
                "totalLen assertion @ mkDmaReadCntrl",
                $format(
                    "dmaReadCntrlReq.sglDmaReadMetaData.totalLen=%0d",
                    dmaReadCntrlReq.sglDmaReadMetaData.totalLen,
                    " should == totalLen=%0d", totalLen
                )
            );
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
        //     "time=%0t: recvReq", $time,
        //     ", SGE sglIdx=%0d", sglIdx,
        //     ", sge.laddr=%h", sge.laddr,
        //     ", mergedLastPktLastFragValidByteNum=%0d", mergedLastPktLastFragValidByteNum,
        //     ", totalLen=%0d", totalLen,
        //     ", sgeNum=%0d", sgeNum,
        //     ", sge.isFirst=", fshow(sge.isFirst),
        //     ", sge.isLast=", fshow(sge.isLast)
        //     // ", sgePktNum=%0d", sgePktNum,
        //     // ", firstPktLen=%0d", firstPktLen,
        //     // ", lastPktLen=%0d", lastPktLen,
        //     // ", pmtuLen=%0d", pmtuLen,
        //     // ", firstPktFragNum=%0d", firstPktFragNum,
        //     // ", lastPktFragNum=%0d", lastPktFragNum
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

        pendingLKeyQ.enq(sge.lkey);
        // $display(
        //     "time=%0t: mkDmaReadCntrl issueChunkReq", $time,
        //     ", addrChunkReq=", fshow(addrChunkReq)
        // );
    endrule

    rule issueDmaReq if (!clearAll && !cancelReg[1]);
        let addrChunkResp <- addrChunkSrv.srvPort.response.get;

        let lkey = pendingLKeyQ.first;
        let { curSQPN, curWorkReqID } = pendingDmaCntrlReqQ.first;

        let dmaReadReq = DmaReadReq {
            initiator: DMA_SRC_SQ_RD,
            sqpn     : curSQPN,
            startAddr: addrChunkResp.chunkAddr,
            len      : addrChunkResp.chunkLen,
            wrID     : curWorkReqID,
            mrIdx    : key2IndexMR(lkey)
        };
        dmaReadSrv.request.put(dmaReadReq);

        let isLastChunkInSGE   = addrChunkResp.isLast;
        let isFirstDmaReqChunk = addrChunkResp.isFirst && addrChunkResp.isOrigFirst;
        let isLastDmaReqChunk  = addrChunkResp.isLast  && addrChunkResp.isOrigLast;
        pendingDmaReadReqQ.enq(tuple2(isFirstDmaReqChunk, isLastDmaReqChunk));

        if (isLastChunkInSGE) begin
            pendingLKeyQ.deq;
        end
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

        let isFirstFragInSGL = dmaResp.dataStream.isFirst && isFirstDmaReqChunk;
        let isLastFragInSGL  = dmaResp.dataStream.isLast && isLastDmaReqChunk;

        let dmaReadCntrlResp = DmaReadCntrlResp {
            dmaReadResp     : dmaResp,
            isFirstFragInSGL: isFirstFragInSGL,
            isLastFragInSGL : isLastFragInSGL
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

    // interface sglTotalPayloadLenMetaDataPipeOut = toPipeOut(sglTotalPayloadLenMetaDataOutQ);
    interface sgeMergedMetaDataPipeOut = toPipeOut(sgeMergedMetaDataOutQ);
    interface sgePktMetaDataPipeOut = addrChunkSrv.sgePktMetaDataPipeOut;
endmodule

typedef enum {
    MERGE_SGE_PAYLOAD_INIT,
    MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT,
    MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT
} MergePayloadStateEachSGE deriving(Bits, Eq, FShow);

module mkMergePayloadEachSGE#(
    Bool clearAll,
    PipeOut#(PktMetaDataSGE) sgePktMetaDataPipeIn,
    PipeOut#(DataStream) sgePayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple6#(ByteEnBitNum, BusBitNum, PktNum, Bool, Bool, Bool)) sgeCurPktMetaDataQ <- mkFIFOF;
    FIFOF#(Tuple5#(DataStream, DataStream, Bool, ByteEnBitNum, BusBitNum)) payloadFragShiftQ <- mkFIFOF;

    // Reg#(ByteEnBitNum)   sgeFirstPktLastFragValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum) sgeFirstPktLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     sgeFirstPktLastFragInvalidBitNumReg <- mkRegU;

    Reg#(Bool) sgeHasOnlyPktReg <- mkRegU;
    Reg#(Bool) hasExtraFragReg <- mkRegU;
    Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(MergePayloadStateEachSGE) stateReg <- mkReg(MERGE_SGE_PAYLOAD_INIT);

    function ActionValue#(DataStream) prepareNextSGE();
        actionvalue
            let {
                firstPktLastFragInvalidByteNum, firstPktLastFragInvalidBitNum,
                sgePktNum, sgeHasJustTwoPkts, sgeHasOnlyPkt, hasExtraFrag
            } = sgeCurPktMetaDataQ.first;
            sgeCurPktMetaDataQ.deq;

            sgeHasOnlyPktReg <= sgeHasOnlyPkt;
            hasExtraFragReg  <= hasExtraFrag;
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
                        remainingPktNum = sgePktNum - 2;
                    end
                end
                else begin
                    stateReg <= MERGE_SGE_PAYLOAD_FIRST_OR_MID_PKT;
                    remainingPktNum = sgePktNum - 1;
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

        sgeCurPktMetaDataQ.clear;
        payloadFragShiftQ.clear;
        stateReg <= MERGE_SGE_PAYLOAD_INIT;
    endrule

    rule handleEachPktMetaData4SGE if (!clearAll);
        let sgePktMetaData = sgePktMetaDataPipeIn.first;
        sgePktMetaDataPipeIn.deq;

        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(sgePktMetaData.firstPktLen);
        let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(sgePktMetaData.lastPktLen);

        let {
            firstPktLastFragValidBitNum,
            firstPktLastFragInvalidByteNum,
            firstPktLastFragInvalidBitNum
        } = calcFragBitNumAndByteNum(firstPktLastFragValidByteNum);
        // let {
        //     lastPktLastFragValidBitNum,
        //     lastPktLastFragInvalidByteNum,
        //     lastPktLastFragInvalidBitNum
        // } = calcFragBitNumAndByteNum(lastPktLastFragValidByteNum);

        let sgeHasJustTwoPkts = isTwoR(sgePktMetaData.sgePktNum);
        let sgeHasOnlyPkt     = isLessOrEqOneR(sgePktMetaData.sgePktNum);

        let hasExtraFrag = lastPktLastFragValidByteNum > firstPktLastFragInvalidByteNum;

        // sgeFirstPktLastFragValidByteNumReg   <= firstPktLastFragValidByteNum;
        sgeCurPktMetaDataQ.enq(tuple6(
            firstPktLastFragInvalidByteNum, firstPktLastFragInvalidBitNum,
            sgePktMetaData.sgePktNum, sgeHasJustTwoPkts, sgeHasOnlyPkt, hasExtraFrag
        ));
    endrule

    rule mergePayloadInit if (!clearAll && stateReg == MERGE_SGE_PAYLOAD_INIT);
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

        // let mergedFrag = mergeFragData(
        //     prePayloadFragReg, curPayloadFrag,
        //     sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
        // );

        // let outPayloadFrag = isFirstPktReg ? prePayloadFragReg : mergedFrag;
        // outPayloadFrag.isFirst = isFirstFragReg;
        // isFirstFragReg <= False;
        // pktPayloadOutQ.enq(outPayloadFrag);

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isFirst = isFirstFragReg;
        isFirstFragReg <= False;
        let shouldShiftPayloadFrag = !isFirstPktReg;
        payloadFragShiftQ.enq(tuple5(
            prePayloadFrag, curPayloadFrag, shouldShiftPayloadFrag,
            sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
        ));
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
        let nextPayloadFrag = genEmptyDataStream;
        // let outPayloadFrag  = prePayloadFragReg;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (sgeCurPktMetaDataQ.notEmpty && sgePayloadPipeIn.notEmpty) begin
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

        // if (!sgeHasOnlyPktReg) begin
        //     outPayloadFrag = mergeFragData(
        //         prePayloadFragReg, nextPayloadFrag,
        //         sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
        //     );
        //     outPayloadFrag.isLast = isLastFrag;
        // end
        // pktPayloadOutQ.enq(outPayloadFrag);

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isLast = isLastFrag;
        let shouldShiftPayloadFrag = !sgeHasOnlyPktReg;
        payloadFragShiftQ.enq(tuple5(
            prePayloadFrag, nextPayloadFrag, shouldShiftPayloadFrag,
            sgeFirstPktLastFragInvalidByteNumReg, sgeFirstPktLastFragInvalidBitNumReg
        ));
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

    rule shiftPayloadFrag if (!clearAll);
        let {
            prePayloadFrag, curPayloadFrag, shouldShiftPayloadFrag,
            sgeFirstPktLastFragInvalidByteNum, sgeFirstPktLastFragInvalidBitNum
        } = payloadFragShiftQ.first;
        payloadFragShiftQ.deq;

        let outPayloadFrag = prePayloadFrag;
        if (shouldShiftPayloadFrag) begin
            outPayloadFrag = mergeFragData(
                prePayloadFrag, curPayloadFrag,
                sgeFirstPktLastFragInvalidByteNum, sgeFirstPktLastFragInvalidBitNum
            );
        end
        pktPayloadOutQ.enq(outPayloadFrag);
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule
/*
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

    function ActionValue#(DataStream) prepareNextSGE();
        actionvalue
            let sgePktMetaData = sgePktMetaDataPipeIn.first;
            sgePktMetaDataPipeIn.deq;

            let firstPktLastFragValidByteNum = calcLastFragValidByteNum(sgePktMetaData.firstPktLen);
            let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(sgePktMetaData.lastPktLen);

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
        let nextPayloadFrag = genEmptyDataStream;
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
*/
typedef enum {
    MERGE_SGL_PAYLOAD_INIT,
    MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE,
    MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE
} MergePayloadStateAllSGE deriving(Bits, Eq, FShow);

module mkMergePayloadAllSGE#(
    Bool clearAll,
    PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeIn,
    PipeOut#(DataStream) sgeMergedPayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple8#(
        ByteEnBitNum, BusBitNum, ByteEnBitNum, BusBitNum, Bool, Bool, Bool, Bool
    )) metaDataQ4EachSGE <- mkFIFOF;
    // Reg#(ByteEnBitNum)   preValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum) preInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     preInvalidBitNumReg <- mkRegU;

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

    function ActionValue#(DataStream) preprocessNextSGL();
        actionvalue
            let {
                curInvalidByteNum, curInvalidBitNum, nextInvalidByteNum, nextInvalidBitNum,
                isOnlySGE, sgeIsFirst, sgeIsLast, hasLessFrag
            } = metaDataQ4EachSGE.first;
            metaDataQ4EachSGE.deq;

            sgeIsOnlyReg <= isOnlySGE;
            sgeIsLastReg <= sgeIsLast;
            isFirstFragReg <= True;

            let curPayloadFrag = sgeMergedPayloadPipeIn.first;
            let nextPrePayloadFrag = curPayloadFrag;

            let nextHasLessFrag = hasLessFrag;
            // If first SGE is single fragment without full byteEn,
            // Wait for the first fragment of next SGE to merge
            if (!isOnlySGE && curPayloadFrag.isLast && hasLessFrag) begin
                nextPrePayloadFrag = genEmptyDataStream;
                nextHasLessFrag = True;
            end
            else begin
                sgeMergedPayloadPipeIn.deq;
                nextHasLessFrag = False;
            end
            hasLessFragReg <= nextHasLessFrag;

            // curValidByteNumReg    <= nextHasLessFrag ? 0 : fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
            curInvalidByteNumReg  <= nextHasLessFrag ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : 0;
            curInvalidBitNumReg   <= nextHasLessFrag ? fromInteger(valueOf(DATA_BUS_WIDTH)) : 0;
            // nextValidByteNumReg   <= nextValidByteNum;
            nextInvalidByteNumReg <= nextInvalidByteNum;
            nextInvalidBitNumReg  <= nextInvalidBitNum;

            let nextState = case ({ pack(sgeIsFirst), pack(sgeIsLast) })
                2'b11, 2'b01: MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE;
                2'b10, 2'b00: MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE;
            endcase;
            stateReg <= nextState;
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
            let {
                curInvalidByteNum, curInvalidBitNum, nextInvalidByteNum, nextInvalidBitNum,
                isOnlySGE, sgeIsFirst, sgeIsLast, hasLessFrag
            } = metaDataQ4EachSGE.first;
            metaDataQ4EachSGE.deq;

            sgeIsLastReg <= sgeIsLast;
            hasLessFragReg <= hasLessFrag;

            // curValidByteNumReg   <= curValidByteNum;
            curInvalidByteNumReg <= curInvalidByteNum;
            curInvalidBitNumReg  <= curInvalidBitNum;

            // nextValidByteNumReg   <= nextValidByteNum;
            nextInvalidByteNumReg <= nextInvalidByteNum;
            nextInvalidBitNumReg  <= nextInvalidBitNum;

            let nextState = case ({ pack(sgeIsFirst), pack(sgeIsLast) })
                2'b11, 2'b01: MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE;
                2'b10, 2'b00: MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE;
            endcase;
            stateReg <= nextState;
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

        metaDataQ4EachSGE.clear;
        stateReg <= MERGE_SGL_PAYLOAD_INIT;
    endrule

    rule handleMetaDataEachSGE if (!clearAll);
        let sgeMergedMetaData = sgeMergedMetaDataPipeIn.first;
        sgeMergedMetaDataPipeIn.deq;

        let isOnlySGE  = sgeMergedMetaData.isFirst && sgeMergedMetaData.isLast;
        let sgeIsFirst = sgeMergedMetaData.isFirst;
        let sgeIsLast  = sgeMergedMetaData.isLast;

        let lastFragValidByteNum = sgeMergedMetaData.lastFragValidByteNum;
        let {
            lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum
        } = calcFragBitNumAndByteNum(lastFragValidByteNum);

        // let curValidByteNum    = 0; // fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        let curInvalidByteNum  = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)); // 0;
        let curInvalidBitNum   = fromInteger(valueOf(DATA_BUS_WIDTH)); // 0;
        // let nextValidByteNum   = lastFragValidByteNum;
        let nextInvalidByteNum = lastFragInvalidByteNum;
        let nextInvalidBitNum  = lastFragInvalidBitNum;

        let hasLessFrag = lastFragValidByteNum < fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        if (!sgeIsFirst) begin
            hasLessFrag = preInvalidByteNumReg >= lastFragValidByteNum;

            // let sumValidByteNum   = preValidByteNumReg   + lastFragValidByteNum;
            let sumInvalidByteNum = preInvalidByteNumReg + lastFragInvalidByteNum;
            let sumInvalidBitNum  = preInvalidBitNumReg  + lastFragInvalidBitNum;

            // curValidByteNum   = preValidByteNumReg;
            curInvalidByteNum = preInvalidByteNumReg;
            curInvalidBitNum  = preInvalidBitNumReg;

            // nextValidByteNum   = sumValidByteNum   & zeroExtend(busByteNumMask);
            nextInvalidByteNum = sumInvalidByteNum & zeroExtend(busByteNumMask);
            nextInvalidBitNum  = sumInvalidBitNum  & zeroExtend(busBitNumMask);
        end

        // preValidByteNumReg   <= nextValidByteNum;
        preInvalidByteNumReg <= nextInvalidByteNum;
        preInvalidBitNumReg  <= nextInvalidBitNum;

        metaDataQ4EachSGE.enq(tuple8(
            curInvalidByteNum, curInvalidBitNum, nextInvalidByteNum, nextInvalidBitNum,
            isOnlySGE, sgeIsFirst, sgeIsLast, hasLessFrag
        ));
    endrule

    rule mergePayloadInit if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_INIT);
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
        let nextPayloadFrag = genEmptyDataStream;
        let outPayloadFrag = prePayloadFragReg;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (metaDataQ4EachSGE.notEmpty && sgeMergedPayloadPipeIn.notEmpty) begin
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
/*
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
                nextPrePayloadFrag = genEmptyDataStream;
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
        let nextPayloadFrag = genEmptyDataStream;
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
*/
interface PayloadSegment;
    interface PipeOut#(PktLen) pktLenPipeOut;
    interface DataStreamPipeOut pktPayloadPipeOut;
endinterface

typedef enum {
    ADJUST_PAYLOAD_SEGMENT_INIT,
    ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT,
    ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT
} AdjustPayloadSegmentState deriving(Bits, Eq, FShow);

module mkAdjustPayloadSegment#(
    Bool clearAll,
    PipeOut#(AdjustedTotalPayloadMetaData) adjustedTotalPayloadMetaDataPipeIn,
    PipeOut#(DataStream) sglAllPayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple8#(
        PMTU, PktFragNum, PktNum, ByteEnBitNum, BusBitNum, Bool, Bool, Bool
    )) sglAdjustedPktMetaDataQ <- mkFIFOF;

    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(ByteEn) firstPktLastFragByteEnReg <- mkRegU;

    Reg#(ByteEnBitNum) firstPktLastFragValidByteNumReg <- mkRegU;
    Reg#(BusBitNum)     firstPktLastFragValidBitNumReg <- mkRegU;

    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(Bool) hasExtraFragReg <- mkRegU;
    Reg#(Bool) sglHasOnlyPktReg <- mkRegU;
    Reg#(Bool) sglHasOnlyFragOnlyPktReg <- mkRegU;

    Reg#(PktFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PktFragNum) pktRemainingFragNumReg <- mkRegU;
    Reg#(PktNum) sglRemainingPktNumReg <- mkRegU;
    Reg#(AdjustPayloadSegmentState) stateReg <- mkReg(ADJUST_PAYLOAD_SEGMENT_INIT);

    function ActionValue#(DataStream) prepareNextSGL();
        actionvalue
            let {
                pmtu, firstPktFragNum, adjustedPktNum, firstPktLastFragValidByteNum,
                firstPktLastFragValidBitNum, sglHasOnlyPkt, hasExtraFrag, isOrigOnlyPkt
            } = sglAdjustedPktMetaDataQ.first;
            sglAdjustedPktMetaDataQ.deq;

            pmtuFragNumReg <= calcFragNumByPMTU(pmtu);

            pktRemainingFragNumReg <= firstPktFragNum;
            sglRemainingPktNumReg  <= adjustedPktNum;

            firstPktLastFragValidByteNumReg <= firstPktLastFragValidByteNum;
            firstPktLastFragValidBitNumReg  <= firstPktLastFragValidBitNum;

            firstPktLastFragByteEnReg <= genByteEn(firstPktLastFragValidByteNum);

            sglHasOnlyPktReg <= sglHasOnlyPkt;
            hasExtraFragReg  <= hasExtraFrag;

            if (sglHasOnlyPkt) begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end

            let curPayloadFrag = sglAllPayloadPipeIn.first;
            sglAllPayloadPipeIn.deq;

            let sglHasOnlyFragOnlyPkt = isOrigOnlyPkt && curPayloadFrag.isLast;
            sglHasOnlyFragOnlyPktReg <= sglHasOnlyFragOnlyPkt;

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

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;

        sglAdjustedPktMetaDataQ.clear;
        stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
    endrule

    rule handleMetaDataEachSGL if (!clearAll);
        let adjustedTotalPayloadMeta = adjustedTotalPayloadMetaDataPipeIn.first;
        adjustedTotalPayloadMetaDataPipeIn.deq;

        let origLastFragValidByteNum     = adjustedTotalPayloadMeta.origLastFragValidByteNum;
        let firstPktLastFragValidByteNum = adjustedTotalPayloadMeta.firstPktLastFragValidByteNum;

        let {
            firstPktLastFragValidBitNum,
            firstPktLastFragInvalidByteNum,
            firstPktLastFragInvalidBitNum
        } = calcFragBitNumAndByteNum(firstPktLastFragValidByteNum);

        let sglHasOnlyPkt = isOneR(adjustedTotalPayloadMeta.adjustedPktNum);
        let hasExtraFrag = firstPktLastFragValidByteNum < origLastFragValidByteNum;
        let isOrigOnlyPkt = isOneR(adjustedTotalPayloadMeta.origPktNum);

        sglAdjustedPktMetaDataQ.enq(tuple8(
            adjustedTotalPayloadMeta.pmtu, adjustedTotalPayloadMeta.firstPktFragNum,
            adjustedTotalPayloadMeta.adjustedPktNum, firstPktLastFragValidByteNum,
            firstPktLastFragValidBitNum, sglHasOnlyPkt, hasExtraFrag, isOrigOnlyPkt
        ));
    endrule

    rule adjustPayloadInit if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_INIT);
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

            sglRemainingPktNumReg <= sglRemainingPktNumReg - 1;

            if (isTwoR(sglRemainingPktNumReg)) begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                pktRemainingFragNumReg <= pmtuFragNumReg;
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end
        end
        else begin
            pktRemainingFragNumReg <= pktRemainingFragNumReg - 1;
        end

        outPayloadFrag.isLast = isLastFrag;
        pktPayloadOutQ.enq(outPayloadFrag);
        // $display(
        //     "time=%0t: adjustFirstOrMidPkt", $time,
        //     ", sglHasOnlyFragOnlyPktReg=", fshow(sglHasOnlyFragOnlyPktReg),
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
        let nextPayloadFrag = genEmptyDataStream;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (sglAdjustedPktMetaDataQ.notEmpty && sglAllPayloadPipeIn.notEmpty) begin
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

            nextPayloadFrag.isFirst = False;
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
/*
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

    // Reg#(PktFragNum) lastPktFragNumReg <- mkRegU;
    Reg#(PktFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PktFragNum) pktRemainingFragNumReg <- mkRegU;
    Reg#(PktNum) sglRemainingPktNumReg <- mkRegU;
    Reg#(AdjustPayloadSegmentState) stateReg <- mkReg(ADJUST_PAYLOAD_SEGMENT_INIT);

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;
        stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
    endrule

    function ActionValue#(DataStream) prepareNextSGL();
        actionvalue
            let adjustedTotalPayloadMeta = adjustedTotalPayloadMetaDataPipeIn.first;
            adjustedTotalPayloadMetaDataPipeIn.deq;

            pmtuFragNumReg <= calcFragNumByPMTU(adjustedTotalPayloadMeta.pmtu);

            pktRemainingFragNumReg <= adjustedTotalPayloadMeta.firstPktFragNum;
            sglRemainingPktNumReg  <= adjustedTotalPayloadMeta.adjustedPktNum;
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

            sglRemainingPktNumReg <= sglRemainingPktNumReg - 1;

            if (isTwoR(sglRemainingPktNumReg)) begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                pktRemainingFragNumReg <= pmtuFragNumReg;
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end
        end
        else begin
            pktRemainingFragNumReg <= pktRemainingFragNumReg - 1;
        end

        outPayloadFrag.isLast = isLastFrag;
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
        let nextPayloadFrag = genEmptyDataStream;

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

            nextPayloadFrag.isFirst = False;
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
*/
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
    WorkReqID         wrID; // TODO: remote it
    QPN               sqpn; // TODO: remote it
    ScatterGatherList sgl;
    Length            totalLen;
    ADDR              raddr;
    PMTU              pmtu;
} PayloadGenReqSG deriving(Bits, FShow);

typedef struct {
    ADDR   raddr;
    PktLen pktLen;
    PAD    padCnt;
    Bool   isFirst;
    Bool   isLast;
} PayloadGenRespSG deriving(Bits, FShow);

typedef struct {
    // Length totalLen;
    PktNum totalPktNum;
    Bool   isOnlyPkt;
    Bool   isZeroPayloadLen;
} PayloadGenTotalMetaData deriving(Bits, FShow);

typedef struct {
    Length totalLen;
    ADDR   origRemoteAddr;
    PMTU   pmtu;
    PktLen pmtuMask;
    PktLen addrAndLenLowPartSum;
    PktLen pmtuLen;
    PktLen lenLowPart;
    PktLen maxFirstPktLen;
    PktNum truncatedPktNum;
    ADDR   pmtuAlignedStartAddr;
    Bool   isZeroPayloadLen;
} TmpPayloadGenMetaData deriving(Bits);

typedef struct {
    ADDR   firstRemoteAddr;
    ADDR   secondRemoteAddr;
    Length totalLen;
    PktNum totalPktNum;
    PktNum origPktNum;
    PktLen firstPktLen;
    PktLen lastPktLen;
    PktLen pmtuLen;
    PMTU   pmtu;
    Bool   isZeroPayloadLen;
} TmpAdjustMetaData deriving(Bits);

typedef struct {
    ADDR         firstRemoteAddr;
    ADDR         secondRemoteAddr;
    PktLen       firstPktLen;
    PktLen       lastPktLen;
    PktLen       pmtuLen;
    ByteEnBitNum firstPktLastFragValidByteNum;
    PAD          firstPktPadCnt;
    ByteEnBitNum lastPktLastFragValidByteNum;
    PAD          lastPktPadCnt;
    PktNum       totalPktNum;
    PMTU         pmtu;
    Bool         isOnlyPkt;
    Bool         isZeroPayloadLen;
} TmpPaddingMetaData deriving(Bits);

interface PayloadGenerator;
    interface Server#(PayloadGenReqSG, PayloadGenRespSG) srvPort;
    interface PipeOut#(PayloadGenTotalMetaData) totalMetaDataPipeOut;
    interface DataStreamPipeOut payloadDataStreamPipeOut;
    method Bool payloadNotEmpty();
endinterface

module mkPayloadGenerator#(
    Bool clearAll, Bool shouldAddPadding, DmaReadCntrl dmaReadCntrl
)(PayloadGenerator);
    FIFOF#(PayloadGenReqSG)            payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadGenRespSG)          payloadGenRespQ <- mkFIFOF;
    FIFOF#(PayloadGenTotalMetaData) totalMetaDataOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(DataStream) sgePayloadOutQ <- mkFIFOF;
    FIFOF#(TmpPayloadGenMetaData) adjustReqPktLenQ <- mkFIFOF;
    FIFOF#(TmpAdjustMetaData) adjustedFirstAndLastPktLenQ <- mkFIFOF;
    FIFOF#(TmpPaddingMetaData) addPadCntQ <- mkFIFOF;
    FIFOF#(AdjustedTotalPayloadMetaData) adjustedTotalPayloadMetaDataQ <- mkFIFOF;

    let sgeMergedPayloadPipeOut <- mkMergePayloadEachSGE(
        clearAll, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );
    let sglMergedPayloadPipeOut <- mkMergePayloadAllSGE(
        clearAll, dmaReadCntrl.sgeMergedMetaDataPipeOut, sgeMergedPayloadPipeOut
    );
    let adjustedPayloadPipeOut <- mkAdjustPayloadSegment(
        clearAll, toPipeOut(adjustedTotalPayloadMetaDataQ), sglMergedPayloadPipeOut
    );

    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let bramQ2PipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);
    let payloadBufPipeOut = bramQ2PipeOut.pipeOut;

    Reg#(ADDR)     pktRemoteAddrReg <- mkRegU;
    Reg#(Bool)        isFirstPktReg <- mkReg(True);
    Reg#(PktNum) remainingPktNumReg <- mkReg(0);

    rule resetAndClear if (clearAll);
        payloadGenReqQ.clear;
        payloadGenRespQ.clear;
        totalMetaDataOutQ.clear;

        sgePayloadOutQ.clear;
        adjustReqPktLenQ.clear;
        adjustedFirstAndLastPktLenQ.clear;
        addPadCntQ.clear;
        adjustedTotalPayloadMetaDataQ.clear;

        payloadBufQ.clear;
        bramQ2PipeOut.clear;

        isFirstPktReg <= True;
        remainingPktNumReg <= 0;
        // $display(
        //     "time=%0t: reset and clear mkPayloadGenerator", $time
        // );
    endrule

    rule recvReq if (!clearAll);
        let payloadGenReq = payloadGenReqQ.first;
        payloadGenReqQ.deq;

        let sglIdx = 0;
        let sge = payloadGenReq.sgl[sglIdx];
        // // If first SGE has zero length, then whole SGL has no payload
        // let isZeroPayloadLen = isZeroR(sge.len);
        let isZeroPayloadLen = isZeroR(payloadGenReq.totalLen);
        if (isZeroPayloadLen) begin
            immAssert(
                sge.isLast,
                "last SGE assertion @ mkDmaReadCntrl",
                $format(
                    "sge.isLast=", fshow(sge.isLast),
                    " should be true when sglIdx=%0d", sglIdx,
                    ", sge.len=%0d", sge.len,
                    ", and totalLen=%0d", payloadGenReq.totalLen
                )
            );
        end

        if (!isZeroPayloadLen) begin
            let dmaReadCntrlReq = DmaReadCntrlReq {
                sglDmaReadMetaData: DmaReadMetaDataSGL {
                    sgl           : payloadGenReq.sgl,
                    totalLen      : payloadGenReq.totalLen,
                    sqpn          : payloadGenReq.sqpn,
                    wrID          : payloadGenReq.wrID
                },
                pmtu              : payloadGenReq.pmtu
            };
            dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);
        end

        let {
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart,
            maxFirstPktLen, truncatedPktNum, pmtuAlignedStartAddr
        } = stepOneCalcPktNumAndPktLenByAddrAndPMTU(
            payloadGenReq.raddr, payloadGenReq.totalLen, payloadGenReq.pmtu
        );

        let tmpPayloadGenMetaData = TmpPayloadGenMetaData {
            totalLen            : payloadGenReq.totalLen,
            origRemoteAddr      : payloadGenReq.raddr,
            pmtu                : payloadGenReq.pmtu,
            pmtuMask            : pmtuMask,
            addrAndLenLowPartSum: addrAndLenLowPartSum,
            pmtuLen             : pmtuLen,
            lenLowPart          : lenLowPart,
            maxFirstPktLen      : maxFirstPktLen,
            truncatedPktNum     : truncatedPktNum,
            pmtuAlignedStartAddr: pmtuAlignedStartAddr,
            isZeroPayloadLen    : isZeroPayloadLen
        };
        adjustReqPktLenQ.enq(tmpPayloadGenMetaData);
        // $display(
        //     "time=%0t: mkPayloadGenerator recvReq", $time,
        //     ", payloadGenReq=", fshow(payloadGenReq)
        // );
    endrule

    rule recvDmaReadCntrlResp if (!clearAll);
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        sgePayloadOutQ.enq(dmaReadCntrlResp.dmaReadResp.dataStream);
    endrule

    rule adjustFirstAndLastPktLen if (!clearAll);
        let tmpPayloadGenMetaData = adjustReqPktLenQ.first;
        adjustReqPktLenQ.deq;

        let totalLen             = tmpPayloadGenMetaData.totalLen;
        let origRemoteAddr       = tmpPayloadGenMetaData.origRemoteAddr;
        let pmtu                 = tmpPayloadGenMetaData.pmtu;
        let pmtuMask             = tmpPayloadGenMetaData.pmtuMask;
        let addrAndLenLowPartSum = tmpPayloadGenMetaData.addrAndLenLowPartSum;
        let pmtuLen              = tmpPayloadGenMetaData.pmtuLen;
        let lenLowPart           = tmpPayloadGenMetaData.lenLowPart;
        let maxFirstPktLen       = tmpPayloadGenMetaData.maxFirstPktLen;
        let truncatedPktNum      = tmpPayloadGenMetaData.truncatedPktNum;
        let pmtuAlignedStartAddr = tmpPayloadGenMetaData.pmtuAlignedStartAddr;
        let isZeroPayloadLen     = tmpPayloadGenMetaData.isZeroPayloadLen;

        let {
            firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr
        } = stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, pmtu
        );

        let { origTruncatedPktNum, origResidue } = truncateLenByPMTU(totalLen, pmtu);
        let origPktNum = origTruncatedPktNum + (isZeroR(origResidue) ? 0 : 1);

        let adjustMetaData = TmpAdjustMetaData {
            firstRemoteAddr : origRemoteAddr,
            secondRemoteAddr: secondChunkStartAddr,
            totalLen        : totalLen,
            totalPktNum     : totalPktNum,
            origPktNum      : origPktNum,
            firstPktLen     : firstPktLen,
            lastPktLen      : lastPktLen,
            pmtuLen         : pmtuLen,
            pmtu            : pmtu,
            isZeroPayloadLen: isZeroPayloadLen
        };
        adjustedFirstAndLastPktLenQ.enq(adjustMetaData);
        // $display(
        //     "time=%0t: mkPayloadGenerator adjustFirstAndLastPktLen", $time,
        //     ", payloadGenReq=", fshow(payloadGenReq)
        // );
    endrule

    rule calcAdjustedTotalPayloadMetaData if (!clearAll);
        let adjustMetaData = adjustedFirstAndLastPktLenQ.first;
        adjustedFirstAndLastPktLenQ.deq;

        let firstRemoteAddr  = adjustMetaData.firstRemoteAddr;
        let secondRemoteAddr = adjustMetaData.secondRemoteAddr;
        let totalLen         = adjustMetaData.totalLen;
        let totalPktNum      = adjustMetaData.totalPktNum;
        let origPktNum       = adjustMetaData.origPktNum;
        let firstPktLen      = adjustMetaData.firstPktLen;
        let lastPktLen       = adjustMetaData.lastPktLen;
        let pmtuLen          = adjustMetaData.pmtuLen;
        let pmtu             = adjustMetaData.pmtu;
        let isZeroPayloadLen = adjustMetaData.isZeroPayloadLen;

        let origLastFragValidByteNum     = calcLastFragValidByteNum(totalLen);
        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(firstPktLen);
        let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(lastPktLen);
        let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        // let lastPktFragNum  = calcFragNumByPktLen(lastPktLen);
        let firstPktPadCnt  = calcPadCnt(firstPktLen);
        let lastPktPadCnt   = calcPadCnt(lastPktLen);
        let isOnlyPkt       = isLessOrEqOneR(totalPktNum);

        let adjustedTotalPayloadMetaData = AdjustedTotalPayloadMetaData {
            firstPktLen                  : firstPktLen,
            firstPktFragNum              : firstPktFragNum,
            firstPktLastFragValidByteNum : firstPktLastFragValidByteNum,
            origLastFragValidByteNum     : origLastFragValidByteNum,
            adjustedPktNum               : totalPktNum,
            origPktNum                   : origPktNum,
            pmtu                         : pmtu
        };
        if (!isZeroPayloadLen) begin
            adjustedTotalPayloadMetaDataQ.enq(adjustedTotalPayloadMetaData);
        end

        let paddingMetaData = TmpPaddingMetaData {
            firstRemoteAddr             : firstRemoteAddr,
            secondRemoteAddr            : secondRemoteAddr,
            firstPktLen                 : firstPktLen,
            lastPktLen                  : lastPktLen,
            pmtuLen                     : pmtuLen,
            firstPktLastFragValidByteNum: firstPktLastFragValidByteNum,
            firstPktPadCnt              : firstPktPadCnt,
            lastPktLastFragValidByteNum : lastPktLastFragValidByteNum,
            lastPktPadCnt               : lastPktPadCnt,
            totalPktNum                 : totalPktNum,
            pmtu                        : pmtu,
            isOnlyPkt                   : isOnlyPkt,
            isZeroPayloadLen            : isZeroPayloadLen
        };
        addPadCntQ.enq(paddingMetaData);

        let totalMetaData = PayloadGenTotalMetaData {
            // totalLen        : totalLen,
            totalPktNum     : totalPktNum,
            isOnlyPkt       : isOnlyPkt,
            isZeroPayloadLen: isZeroPayloadLen
        };
        totalMetaDataOutQ.enq(totalMetaData);
        // $display(
        //     "time=%0t: mkPayloadGenerator calcAdjustedTotalPayloadMetaData", $time,
        //     ", adjustedTotalPayloadMetaData=", fshow(adjustedTotalPayloadMetaData)
        // );
    endrule

    rule genRespAndAddPadding if (!clearAll);
        let paddingMetaData = addPadCntQ.first;

        let firstRemoteAddr              = paddingMetaData.firstRemoteAddr;
        let secondRemoteAddr             = paddingMetaData.secondRemoteAddr;
        let firstPktLen                  = paddingMetaData.firstPktLen;
        let lastPktLen                   = paddingMetaData.lastPktLen;
        let pmtuLen                      = paddingMetaData.pmtuLen;
        let firstPktLastFragValidByteNum = paddingMetaData.firstPktLastFragValidByteNum;
        let firstPktPadCnt               = paddingMetaData.firstPktPadCnt;
        let lastPktLastFragValidByteNum  = paddingMetaData.lastPktLastFragValidByteNum;
        let lastPktPadCnt                = paddingMetaData.lastPktPadCnt;
        let totalPktNum                  = paddingMetaData.totalPktNum;
        let pmtu                         = paddingMetaData.pmtu;
        let isOnlyPkt                    = paddingMetaData.isOnlyPkt;
        let isZeroPayloadLen             = paddingMetaData.isZeroPayloadLen;

        let firstPktLastFragValidByteNumWithPadding = firstPktLastFragValidByteNum + zeroExtend(firstPktPadCnt);
        let lastPktLastFragValidByteNumWithPadding  = lastPktLastFragValidByteNum  + zeroExtend(lastPktPadCnt);
        let firstPktLastFragByteEnWithPadding = genByteEn(firstPktLastFragValidByteNumWithPadding);
        let lastPktLastFragByteEnWithPadding  = genByteEn(lastPktLastFragValidByteNumWithPadding);
        immAssert(
            (fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - zeroExtend(firstPktPadCnt) >= firstPktLastFragValidByteNum) &&
            (fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - zeroExtend(lastPktPadCnt)  >= lastPktLastFragValidByteNum),
            "zero SGE assertion @ mkPayloadGenerator",
            $format(
                "firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
                " + firstPktPadCnt=%0d", firstPktPadCnt,
                " should not > DATA_BUS_BYTE_WIDTH=%0d", valueOf(DATA_BUS_BYTE_WIDTH),
                ", and lastPktLastFragValidByteNum=%0d", lastPktLastFragValidByteNum,
                " + lastPktPadCnt=%0d", lastPktPadCnt,
                " should not > DATA_BUS_BYTE_WIDTH=%0d", valueOf(DATA_BUS_BYTE_WIDTH)
            )
        );
        let oneAsPSN   = 1;
        let remoteAddr = firstRemoteAddr;
        let nextRemoteAddr  = pktRemoteAddrReg;
        let remainingPktNum = remainingPktNumReg;
        if (isFirstPktReg) begin
            nextRemoteAddr = secondRemoteAddr;

            if (isOnlyPkt) begin
                remainingPktNum = 0;
            end
            else begin
                remainingPktNum = totalPktNum - 2;
            end
        end
        else begin
            remoteAddr     = pktRemoteAddrReg;
            nextRemoteAddr = addrAddPsnMultiplyPMTU(
                pktRemoteAddrReg, oneAsPSN, pmtu
            );
            remainingPktNum = remainingPktNumReg - 1;
        end

        let isFirstPkt = isFirstPktReg;
        let isLastPkt  = isOnlyPkt || (!isFirstPktReg && isZeroR(remainingPktNumReg));
        let pktLen = isFirstPkt ? firstPktLen    : (isLastPkt ? lastPktLen : pmtuLen);
        let padCnt = isFirstPkt ? firstPktPadCnt : (isLastPkt ? lastPktPadCnt : 0);

        if (isZeroPayloadLen) begin
            isFirstPktReg <= True;
            addPadCntQ.deq;

            let payloadGenResp = PayloadGenRespSG {
                raddr           : remoteAddr,
                pktLen          : 0,
                padCnt          : 0,
                isFirst         : True,
                isLast          : True
            };
            payloadGenRespQ.enq(payloadGenResp);
        end
        else begin
            let curPayloadFrag = adjustedPayloadPipeOut.first;
            adjustedPayloadPipeOut.deq;

            let isLastFragInFirstPkt = curPayloadFrag.isLast && isFirstPkt;
            let isLastFragInLastPkt  = curPayloadFrag.isLast && isLastPkt;

            if (isLastFragInLastPkt) begin
                addPadCntQ.deq;

                if (shouldAddPadding) begin
                    curPayloadFrag.byteEn = lastPktLastFragByteEnWithPadding;
                end
            end
            if (isLastFragInFirstPkt) begin
                if (shouldAddPadding) begin
                    curPayloadFrag.byteEn = firstPktLastFragByteEnWithPadding;
                end
            end

            if (curPayloadFrag.isLast) begin
                isFirstPktReg      <= isLastFragInLastPkt;
                pktRemoteAddrReg   <= nextRemoteAddr;
                remainingPktNumReg <= remainingPktNum;
            end
            // Generate response by the end of the payload
            // Every segmented payload has a payloadGenResp
            if (curPayloadFrag.isLast) begin
                let payloadGenResp = PayloadGenRespSG {
                    raddr           : remoteAddr,
                    pktLen          : pktLen,
                    padCnt          : padCnt,
                    isFirst         : isFirstPkt,
                    isLast          : isLastPkt
                };
                payloadGenRespQ.enq(payloadGenResp);
                // $display(
                //     "time=%0t: genRespAndAddPadding", $time,
                //     ", payloadGenResp=", fshow(payloadGenResp)
                // );
            end

            payloadBufQ.enq(curPayloadFrag);
            // $display(
            //     "time=%0t: genRespAndAddPadding", $time,
            //     ", remainingPktNumReg=%0d", remainingPktNumReg,
            //     ", isFirstPktReg=", fshow(isFirstPktReg),
            //     ", isOnlyPkt=", fshow(isOnlyPkt),
            //     ", isLastFragInFirstPkt=", fshow(isLastFragInFirstPkt),
            //     ", isLastFragInLastPkt=", fshow(isLastFragInLastPkt),
            //     ", isFirstPkt=", fshow(isFirstPkt),
            //     ", isLastPkt=", fshow(isLastPkt),
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast)
            // );
        end
        // $display(
        //     "time=%0t: PayloadGenerator genRespAndAddPadding", $time,
        //     ", isZeroPayloadLen=", fshow(isZeroPayloadLen),
        //     ", isFirstPkt=", fshow(isFirstPkt),
        //     ", isLastPkt=", fshow(isLastPkt),
        //     ", remainingPktNum=%0d", remainingPktNum
        // );
    endrule

    interface srvPort = toGPServer(payloadGenReqQ, payloadGenRespQ);
    interface totalMetaDataPipeOut = toPipeOut(totalMetaDataOutQ);
    interface payloadDataStreamPipeOut = payloadBufPipeOut;
    method Bool payloadNotEmpty() = bramQ2PipeOut.notEmpty;
endmodule
