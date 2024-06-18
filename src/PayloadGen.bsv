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
import RdmaUtils :: *;

typedef union tagged {
    IMM  Imm;
    RKEY RKey;
} ImmOrRKey deriving(Bits, FShow);

typedef struct {
    PKEY pkey;
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
            ", msn(pkey)=", fshow(wqe.pkey),
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
    Bool                  isFirst;
    Bool                  isLast;
} MergedMetaDataSGE deriving(Bits, FShow);

// typedef struct {
//     QPN       sqpn; // TODO: remove it
//     WorkReqID wrID; // TODO: remove it
//     Length    totalLen;
//     PMTU      pmtu;
// } TotalPayloadLenMetaDataSGL deriving(Bits, FShow);

typedef struct {
    PktLen                firstPktLen;
    PktFragNum            firstPktFragNum;
    ByteEnBitNum firstPktLastFragValidByteNum;
    ByteEnBitNum origLastFragValidByteNum;
    PktNum                adjustedPktNum;
    PMTU                  pmtu;
} AdjustedTotalPayloadMetaData deriving(Bits, FShow);

typedef struct {
    ScatterGatherList sgl;
    Length totalLen;
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

typedef Bit#(TWO) PktNumAddOn;

function Tuple6#(ADDR, PktLen, PktNumAddOn, Bool, Bool, Bool) stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
    ADDR pmtuAlignedStartAddr, PMTU pmtu, PktLen pmtuMask,
    PktLen addrAndLenLowPartSum, PktNum truncatedPktNum
);
    let oneAsPSN = 1;
    let secondChunkStartAddr = addrAddPsnMultiplyPMTU(pmtuAlignedStartAddr, oneAsPSN, pmtu);

    ResiduePMTU residue  = truncateByPMTU(addrAndLenLowPartSum, pmtu);
    PktLen tmpLastPktLen = zeroExtend(residue);

    let pmtuInvMask = ~pmtuMask;
    let noResidue   = isZeroR(pmtuMask & addrAndLenLowPartSum);
    let noExtraPkt  = isZeroR(pmtuInvMask & addrAndLenLowPartSum);
    let hasResidue  = !noResidue;
    let hasExtraPkt = !noExtraPkt;
    let notFullPkt  = isZeroR(truncatedPktNum);
    PktNumAddOn residuePktNum = zeroExtend(pack(hasResidue));
    PktNumAddOn extraPktNum   = zeroExtend(pack(hasExtraPkt));

    let pktNumAddOne = residuePktNum + extraPktNum;
    return tuple6(secondChunkStartAddr, tmpLastPktLen, pktNumAddOne, notFullPkt, hasExtraPkt, hasResidue);
endfunction

function Tuple3#(PktLen, PktLen, PktNum) stepThreeCalcPktNumAndPktLenByAddrAndPMTU(
    PktNum truncatedPktNum, PktNumAddOn pktNumAddOne, PktLen lenLowPart,
    PktLen maxFirstPktLen, PktLen tmpLastPktLen, PktLen pmtuLen,
    Bool notFullPkt, Bool hasExtraPkt, Bool hasResidue
);
    let totalPktNum = truncatedPktNum + zeroExtend(pktNumAddOne);
    let firstPktLen = (notFullPkt && !hasExtraPkt) ? lenLowPart : maxFirstPktLen;
    let lastPktLen  = hasResidue ? tmpLastPktLen : (notFullPkt ? lenLowPart : pmtuLen);

    return tuple3(firstPktLen, lastPktLen, totalPktNum);
endfunction
/*
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
*/
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
function DataStream leftShiftAndMergeFragData(
    DataStream preFrag,
    DataStream curFrag,
    ShiftByteNum leftShiftByteNum
);
    let resultFrag    = preFrag;
    let {outByteNum, isByteSumOverflow} = satAddTwoByteNum(preFrag.byteNum, curFrag.byteNum);

    resultFrag.byteNum = outByteNum;
    resultFrag.data   = truncateLSB({ preFrag.data, curFrag.data } << getFragEnBitNumByByteEnNum(unpack(zeroExtend(leftShiftByteNum))));
    return resultFrag;
endfunction

function DataStream genEmptyDataStream();
    return DataStream {
        data: 0,
        byteNum: 0,
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
    PktNumAddOn pktNumAddOne;
    PktNum      truncatedPktNum;
    PktLen      lenLowPart;
    PktLen      maxFirstPktLen;
    PktLen      tmpLastPktLen;
    PktLen      pmtuLen;
    // Length      totalLen;
    PMTU        pmtu;
    ADDR        startAddr;
    ADDR        nextAddr;
    Bool        notFullPkt;
    Bool        hasExtraPkt;
    Bool        hasResidue;
    Bool        isOrigFirst;
    Bool        isOrigLast;
} TmpPktMetaDataSGE deriving(Bits);

typedef struct {
    PktNum sgePktNum;
    PktLen firstPktLen;
    PktLen pmtuLen;
    PktLen lastPktLen;
    PMTU   pmtu;
    ADDR   startAddr;
    ADDR   nextAddr;
    Bool   isOrigFirst;
    Bool   isOrigLast;
} TmpChunkRespData deriving(Bits);

module mkAddrChunkSrv#(Bool clearAll)(AddrChunkSrv);
    FIFOF#(AddrChunkReq)   reqQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(AddrChunkResp) respQ <- mkFIFOF;
    FIFOF#(PktMetaDataSGE) sgePktMetaDataOutQ <- mkFIFOF;

    // Pipeline FIFOF
    FIFOF#(Tuple8#(
        PktLen, PktLen, PktLen, PktLen, PktLen, PktNum, ADDR, AddrChunkReq
    )) calcChunkMetaDataQ <- mkFIFOF;
    FIFOF#(TmpPktMetaDataSGE) calcPktMetaDataQ4SGE <- mkFIFOF;
    FIFOF#(TmpChunkRespData) calcAddrChunkRespQ <- mkFIFOF;

    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(ADDR)     nextChunkAddrReg <- mkRegU;
    Reg#(Bool)      isFirstChunkReg <- mkReg(True);

    // rule debug;
    //     if (!reqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv reqQ");
    //     end
    //     if (!respQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv respQ");
    //     end
    //     if (!sgePktMetaDataOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv sgePktMetaDataOutQ");
    //     end
    //     if (!calcChunkMetaDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv calcChunkMetaDataQ");
    //     end
    //     if (!calcPktMetaDataQ4SGE.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv calcPktMetaDataQ4SGE");
    //     end
    //     if (!calcAddrChunkRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAddrChunkSrv calcAddrChunkRespQ");
    //     end
        

    // endrule

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        sgePktMetaDataOutQ.clear;

        calcChunkMetaDataQ.clear;
        calcPktMetaDataQ4SGE.clear;
        calcAddrChunkRespQ.clear;

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

        calcChunkMetaDataQ.enq(tuple8(
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, addrChunkReq
        ));
    endrule

    rule calcChunkMetaData if (!clearAll);
        let {
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart, maxFirstPktLen,
            truncatedPktNum, pmtuAlignedStartAddr, addrChunkReq
        } = calcChunkMetaDataQ.first;
        calcChunkMetaDataQ.deq;

        let {
            secondChunkStartAddr, tmpLastPktLen, pktNumAddOne,
            notFullPkt, hasExtraPkt, hasResidue
        } = stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
            pmtuAlignedStartAddr, addrChunkReq.pmtu, pmtuMask,
            addrAndLenLowPartSum, truncatedPktNum
        );

        let tmpPktMetaDataSGE = TmpPktMetaDataSGE {
            pktNumAddOne   : pktNumAddOne,
            truncatedPktNum: truncatedPktNum,
            lenLowPart     : lenLowPart,
            maxFirstPktLen : maxFirstPktLen,
            tmpLastPktLen  : tmpLastPktLen,
            pmtuLen        : pmtuLen,
            // totalLen       : addrChunkReq.len,
            pmtu           : addrChunkReq.pmtu,
            startAddr      : addrChunkReq.startAddr,
            nextAddr       : secondChunkStartAddr,
            notFullPkt     : notFullPkt,
            hasExtraPkt    : hasExtraPkt,
            hasResidue     : hasResidue,
            isOrigFirst    : addrChunkReq.isFirst,
            isOrigLast     : addrChunkReq.isLast
        };
        calcPktMetaDataQ4SGE.enq(tmpPktMetaDataSGE);

        // $display(
        //     "time=%0t: mkAddrChunkSrv recvReq", $time,
        //     ", addrChunkReq.len=%0d", addrChunkReq.len,
        //     ", sgePktNum=%0d", sgePktNum,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen
        // );
    endrule

    rule genPktMetaDataSGE if (!clearAll);
        let tmpPktMetaDataSGE = calcPktMetaDataQ4SGE.first;
        calcPktMetaDataQ4SGE.deq;

        let pktNumAddOne    = tmpPktMetaDataSGE.pktNumAddOne;
        let truncatedPktNum = tmpPktMetaDataSGE.truncatedPktNum;
        let lenLowPart      = tmpPktMetaDataSGE.lenLowPart;
        let maxFirstPktLen  = tmpPktMetaDataSGE.maxFirstPktLen;
        let tmpLastPktLen   = tmpPktMetaDataSGE.tmpLastPktLen;
        let pmtuLen         = tmpPktMetaDataSGE.pmtuLen;
        // let totalLen        = tmpPktMetaDataSGE.totalLen;
        let pmtu            = tmpPktMetaDataSGE.pmtu;
        let startAddr       = tmpPktMetaDataSGE.startAddr;
        let nextAddr        = tmpPktMetaDataSGE.nextAddr;
        let notFullPkt      = tmpPktMetaDataSGE.notFullPkt;
        let hasExtraPkt     = tmpPktMetaDataSGE.hasExtraPkt;
        let hasResidue      = tmpPktMetaDataSGE.hasResidue;
        let isOrigFirst     = tmpPktMetaDataSGE.isOrigFirst;
        let isOrigLast      = tmpPktMetaDataSGE.isOrigLast;

        let {
            firstPktLen, lastPktLen, sgePktNum
        } = stepThreeCalcPktNumAndPktLenByAddrAndPMTU(
            truncatedPktNum, pktNumAddOne, lenLowPart, maxFirstPktLen,
            tmpLastPktLen, pmtuLen, notFullPkt, hasExtraPkt, hasResidue
        );
        immAssert(
            !isZero(firstPktLen) && !isZero(lastPktLen),
            "firstPktLen lastPktLen assertion @ mkAddrChunkSrv",
            $format(
                "firstPktLen=%0d", firstPktLen,
                " and lastPktLen=%0d", lastPktLen,
                // " should not be zero, when totalLen=%0d", totalLen,
                " should not be zero, when lenLowPart=%0d", lenLowPart,
                ", maxFirstPktLen=%0d", maxFirstPktLen,
                ", tmpLastPktLen=%0d", tmpLastPktLen,
                ", startAddr=%h", startAddr,
                ", pmtu=", fshow(pmtu),
                ", notFullPkt=", fshow(notFullPkt),
                ", hasExtraPkt=", fshow(hasExtraPkt),
                ", hasResidue=", fshow(hasResidue)
            )
        );

        let sgePktMetaData = PktMetaDataSGE {
            firstPktLen: firstPktLen,
            lastPktLen : lastPktLen,
            sgePktNum  : sgePktNum,
            pmtu       : pmtu
        };
        sgePktMetaDataOutQ.enq(sgePktMetaData);

        let tmpChunkRespData = TmpChunkRespData {
            sgePktNum  : sgePktNum,
            firstPktLen: firstPktLen,
            pmtuLen    : pmtuLen,
            lastPktLen : lastPktLen,
            pmtu       : pmtu,
            startAddr  : startAddr,
            nextAddr   : nextAddr,
            isOrigFirst: isOrigFirst,
            isOrigLast : isOrigLast
        };
        calcAddrChunkRespQ.enq(tmpChunkRespData);
    endrule

    rule genResp if (!clearAll);
        let tmpChunkRespData = calcAddrChunkRespQ.first;

        let sgePktNum   = tmpChunkRespData.sgePktNum;
        let firstPktLen = tmpChunkRespData.firstPktLen;
        let pmtuLen     = tmpChunkRespData.pmtuLen;
        let lastPktLen  = tmpChunkRespData.lastPktLen;
        let pmtu        = tmpChunkRespData.pmtu;
        let startAddr   = tmpChunkRespData.startAddr;
        let nextAddr    = tmpChunkRespData.nextAddr;
        let isOrigFirst = tmpChunkRespData.isOrigFirst;
        let isOrigLast  = tmpChunkRespData.isOrigLast;

        let oneAsPSN = 1;
        let nextChunkAddr   = addrAddPsnMultiplyPMTU(nextChunkAddrReg, oneAsPSN, pmtu);
        let remainingPktNum = remainingPktNumReg;
        if (isFirstChunkReg) begin
            nextChunkAddr   = nextAddr;
            remainingPktNum = sgePktNum;
        end

        let isLastChunk = remainingPktNum == 1;
        if (isLastChunk) begin
            calcAddrChunkRespQ.deq;
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
        reqQ.notEmpty                 ||
        respQ.notEmpty                ||
        calcChunkMetaDataQ.notEmpty   ||
        calcPktMetaDataQ4SGE.notEmpty ||
        calcAddrChunkRespQ.notEmpty   ||
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
`ifdef SUPPORT_SGL
    interface PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeOut;
`endif
endinterface

module mkDmaReadCntrl#(
    Bool clearAll, DmaReadSrv dmaReadSrv
)(DmaReadCntrl);
    FIFOF#(DmaReadCntrlReq)   reqQ <- mkFIFOF;
    FIFOF#(DmaReadCntrlResp) respQ <- mkFIFOF;
`ifdef SUPPORT_SGL
    FIFOF#(MergedMetaDataSGE) sgeMergedMetaDataOutQ <- mkSizedFIFOF(valueOf(MAX_SGE));
`endif

    // Pipeline FIFO
    FIFOF#(Tuple2#(ScatterGatherElem, PMTU)) pendingScatterGatherElemQ <- mkSizedFIFOF(valueOf(MAX_SGE));
    FIFOF#(LKEY) pendingLKeyQ <- mkSizedFIFOF(5);
    FIFOF#(Tuple2#(Bool, Bool))     pendingDmaReadReqQ <-  mkSizedFIFOF(valueOf(DMA_READ_INFLIGHT_QUEUE_LENGTH));


    // rule debug;
    //     if (!reqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl reqQ");
    //     end
    //     if (!respQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl respQ");
    //     end
    //     if (!sgeMergedMetaDataOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl sgeMergedMetaDataOutQ");
    //     end
    //     if (!pendingScatterGatherElemQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl pendingScatterGatherElemQ");
    //     end
    //     if (!pendingLKeyQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl pendingLKeyQ");
    //     end
    //     if (!pendingDmaReadReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadCntrl pendingDmaReadReqQ");
    //     end
    // endrule




    let addrChunkSrv <- mkAddrChunkSrv(clearAll);

    Reg#(Bool) gracefulStopReg[2] <- mkCReg(2, False);
    Reg#(Bool)       cancelReg[2] <- mkCReg(2, False);

    Reg#(NumSGE)   sgeNumReg <- mkRegU;
    Reg#(IdxSGL)   sglIdxReg <- mkReg(0);

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
`ifdef SUPPORT_SGL
        sgeMergedMetaDataOutQ.clear;
`endif
        // sglTotalPayloadLenMetaDataOutQ.clear;

        pendingScatterGatherElemQ.clear;
        pendingLKeyQ.clear;
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
        
`ifdef SUPPORT_SGL
        let sgeMergedMetaData = MergedMetaDataSGE {
            lastFragValidByteNum: mergedLastPktLastFragValidByteNum,
            isFirst             : sge.isFirst,
            isLast              : sge.isLast
        };
        sgeMergedMetaDataOutQ.enq(sgeMergedMetaData);
`endif
        pendingScatterGatherElemQ.enq(tuple2(sge, dmaReadCntrlReq.pmtu));

        let sgeNum = sgeNumReg;
        if (sge.isFirst) begin
            sgeNum = 1;
        end
        else begin
            sgeNum = sgeNumReg + 1;
        end

        // TODO: make sure segnum will be optmized out by backend tool?
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
            //     pmtu    : dmaReadCntrlReq.pmtu
            // };
            // sglTotalPayloadLenMetaDataOutQ.enq(sglTotalPayloadLenMetaData);
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

        let dmaReadReq = DmaReadReq {
            startAddr: addrChunkResp.chunkAddr,
            len      : addrChunkResp.chunkLen,
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
        $display(
            "time=%0t: mkDmaReadCntrl issueDmaReq", $time,
            ", addrChunkResp=", fshow(addrChunkResp),
            ", dmaReadReq=", fshow(dmaReadReq)
        );
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
        $display(
            "time=%0t: mkDmaReadCntrl recvDmaResp", $time,
            ", resp=", fshow(dmaResp),
            ", isFirstDmaReqChunk=", fshow(isFirstDmaReqChunk),
            ", isLastDmaReqChunk=", fshow(isLastDmaReqChunk),
            ", isFirstFragInSGL=", fshow(isFirstFragInSGL),
            ", isLastFragInSGL=", fshow(isLastFragInSGL)
        );
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

`ifdef SUPPORT_SGL
    interface sgeMergedMetaDataPipeOut = toPipeOut(sgeMergedMetaDataOutQ);
`endif

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
    FIFOF#(Tuple5#(ByteEnBitNum, PktNum, Bool, Bool, Bool)) sgeCurPktMetaDataQ <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, DataStream, ByteEnBitNum)) payloadFragShiftQ <- mkFIFOF;

    Reg#(ByteEnBitNum) sgeFirstPktLastFragInvalidByteNumReg <- mkRegU;

    Reg#(Bool) sgeHasOnlyPktReg <- mkRegU;
    Reg#(Bool) hasExtraFragReg <- mkRegU;
    Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(MergePayloadStateEachSGE) stateReg <- mkReg(MERGE_SGE_PAYLOAD_INIT);


    // rule debug;
    //     if (!pktPayloadOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadEachSGE pktPayloadOutQ");
    //     end
    //     if (!sgeCurPktMetaDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadEachSGE sgeCurPktMetaDataQ");
    //     end
    //     if (!payloadFragShiftQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadEachSGE payloadFragShiftQ");
    //     end
    //     if (!sgePayloadPipeIn.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkMergePayloadEachSGE sgePayloadPipeIn");
    //     end
    // endrule



    function ActionValue#(DataStream) prepareNextSGE();
        actionvalue
            let {
                firstPktLastFragInvalidByteNum,
                sgePktNum, sgeHasJustTwoPkts, sgeHasOnlyPkt, hasExtraFrag
            } = sgeCurPktMetaDataQ.first;
            sgeCurPktMetaDataQ.deq;

            sgeHasOnlyPktReg <= sgeHasOnlyPkt;
            hasExtraFragReg  <= hasExtraFrag;
            sgeFirstPktLastFragInvalidByteNumReg <= firstPktLastFragInvalidByteNum;

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
                    nextPrePayloadFrag.data   = curPayloadFrag.data   >> getFragEnBitNumByByteEnNum(zeroExtend(firstPktLastFragInvalidByteNum));

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
            //     ", firstPktLastFragInvalidByteNum=%0d", firstPktLastFragInvalidByteNum,
            //     // ", sgeFirstPktLastFragValidByteNumReg=%0d", sgeFirstPktLastFragValidByteNumReg,
            //     ", sgeFirstPktLastFragInvalidByteNumReg=%0d", sgeFirstPktLastFragInvalidByteNumReg,
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            //     ", curPayloadFrag.byteNum=%h", curPayloadFrag.byteNum
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

        let firstPktLastFragInvalidByteNum = calcFragInvalidByteNum(firstPktLastFragValidByteNum);

        let sgeHasJustTwoPkts = isTwoR(sgePktMetaData.sgePktNum);
        let sgeHasOnlyPkt     = isLessOrEqOneR(sgePktMetaData.sgePktNum);

        let hasExtraFrag = lastPktLastFragValidByteNum > firstPktLastFragInvalidByteNum;

        sgeCurPktMetaDataQ.enq(tuple5(
            firstPktLastFragInvalidByteNum,
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
                nextPrePayloadFrag.data   = curPayloadFrag.data   >> getFragEnBitNumByByteEnNum(zeroExtend(sgeFirstPktLastFragInvalidByteNumReg));
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
                "remainingPktNumReg=", fshow(remainingPktNumReg),
                " should > 0 when stateReg=", fshow(stateReg)
            )
        );

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isFirst = isFirstFragReg;
        isFirstFragReg <= False;
        let shouldShiftPayloadFrag = !isFirstPktReg;

        let leftShiftInvalidByteNum = sgeFirstPktLastFragInvalidByteNumReg;
        if (!shouldShiftPayloadFrag) begin
            leftShiftInvalidByteNum = 0;
        end
        payloadFragShiftQ.enq(tuple3(
            prePayloadFrag, curPayloadFrag,
            leftShiftInvalidByteNum
        ));
        // $display(
        //     "time=%0t: mergeFirstOrMidPktSGE", $time,
        //     ", sgeFirstPktLastFragInvalidByteNumReg=%0d", sgeFirstPktLastFragInvalidByteNumReg,
        //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     ", curPayloadFrag.byteNum=%h", curPayloadFrag.byteNum,
        //     ", prePayloadFrag.isFirst=", fshow(prePayloadFrag.isFirst),
        //     ", prePayloadFrag.isLast=", fshow(prePayloadFrag.isLast),
        //     ", prePayloadFrag.byteNum=%h", prePayloadFrag.byteNum
        // );
    endrule

    rule mergeLastOrOnlyPktSGE if (!clearAll && stateReg == MERGE_SGE_PAYLOAD_LAST_OR_ONLY_PKT);
        let nextPayloadFrag = genEmptyDataStream;

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

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isLast = isLastFrag;
        let shouldShiftPayloadFrag = !sgeHasOnlyPktReg;

        let leftShiftInvalidByteNum = sgeFirstPktLastFragInvalidByteNumReg;
        if (!shouldShiftPayloadFrag) begin
            leftShiftInvalidByteNum = 0;
        end
        payloadFragShiftQ.enq(tuple3(
            prePayloadFrag, nextPayloadFrag,
            leftShiftInvalidByteNum
        ));
        $display(
            "time=%0t: mergeLastOrOnlyPktSGE", $time,
            ", sgeHasOnlyPktReg=", fshow(sgeHasOnlyPktReg),
            ", hasExtraFragReg=", fshow(hasExtraFragReg),
            ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
            ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
            ", prePayloadFragReg.byteNum=%h", prePayloadFragReg.byteNum,
            ", nextPayloadFrag.isFirst=", fshow(nextPayloadFrag.isFirst),
            ", nextPayloadFrag.isLast=", fshow(nextPayloadFrag.isLast),
            ", nextPayloadFrag.byteNum=%h", nextPayloadFrag.byteNum,
            ", prePayloadFrag.isFirst=", fshow(prePayloadFrag.isFirst),
            ", prePayloadFrag.isLast=", fshow(prePayloadFrag.isLast),
            ", prePayloadFrag.byteNum=%h", prePayloadFrag.byteNum
        );
    endrule

    rule shiftPayloadFrag if (!clearAll);
        let {
            prePayloadFrag, curPayloadFrag,
            leftShiftInvalidByteNum
        } = payloadFragShiftQ.first;
        payloadFragShiftQ.deq;

        let outPayloadFrag = leftShiftAndMergeFragData(
            prePayloadFrag, curPayloadFrag,
            truncate(leftShiftInvalidByteNum)
        );
        pktPayloadOutQ.enq(outPayloadFrag);
        $display(
            "time=%0t: shiftPayloadFrag @ mkMergePayloadEachSGE", $time,
            ", sgeHasOnlyPktReg=", fshow(sgeHasOnlyPktReg),
            ", hasExtraFragReg=", fshow(hasExtraFragReg),
            ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            ", curPayloadFrag.byteNum=%h", curPayloadFrag.byteNum,
            ", prePayloadFrag.isFirst=", fshow(prePayloadFrag.isFirst),
            ", prePayloadFrag.isLast=", fshow(prePayloadFrag.isLast),
            ", prePayloadFrag.byteNum=%h", prePayloadFrag.byteNum,
            ", leftShiftInvalidByteNum=", fshow(leftShiftInvalidByteNum),
            ", outPayloadFrag=", fshow(outPayloadFrag)
        );
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule

typedef enum {
    MERGE_SGL_PAYLOAD_INIT,
    MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE,
    MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE
} MergePayloadStateAllSGE deriving(Bits, Eq, FShow);

typedef struct {
    ByteEnBitNum lastFragInvalidByteNum;
    ByteEnBitNum curInvalidByteNum;
    Bool                   isOnlySGE;
    Bool                   sgeIsFirst;
    Bool                   sgeIsLast;
    Bool                   hasLessFrag;
} TmpMergedMetaDataSGE deriving(Bits);

module mkMergePayloadAllSGE#(
    Bool clearAll,
    PipeOut#(MergedMetaDataSGE) sgeMergedMetaDataPipeIn,
    PipeOut#(DataStream) sgeMergedPayloadPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) pktPayloadOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(TmpMergedMetaDataSGE) mergedMetaDataQ4EachSGE <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, DataStream, ByteEnBitNum)) payloadFragShiftQ <- mkFIFOF;

    // rule debug;
    //     if (!pktPayloadOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadAllSGE pktPayloadOutQ");
    //     end
    //     if (!mergedMetaDataQ4EachSGE.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadAllSGE mergedMetaDataQ4EachSGE");
    //     end
    //     if (!payloadFragShiftQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkMergePayloadAllSGE payloadFragShiftQ");
    //     end
    // endrule


    Reg#(ByteEnBitNum) preInvalidByteNumReg <- mkRegU;

    Reg#(ByteEnBitNum) lastFragInvalidByteNumReg <- mkRegU;

    Reg#(ByteEnBitNum)  curInvalidByteNumReg <- mkRegU;

    Reg#(Bool) isFirstFragReg <- mkRegU;
    Reg#(Bool) sgeIsOnlyReg   <- mkRegU;
    Reg#(Bool) sgeIsLastReg   <- mkRegU;
    Reg#(Bool) hasLessFragReg <- mkRegU;
    Reg#(DataStream) prePayloadFragReg <- mkRegU;
    Reg#(MergePayloadStateAllSGE) stateReg <- mkReg(MERGE_SGL_PAYLOAD_INIT);

    BusByteWidthMask busByteNumMask = maxBound;
    BusBitWidthMask  busBitNumMask  = maxBound;

    function ActionValue#(DataStream) preprocessNextSGL();
        actionvalue
            let tmpMergedMetaDataSGE = mergedMetaDataQ4EachSGE.first;
            mergedMetaDataQ4EachSGE.deq;

            let lastFragInvalidByteNum = tmpMergedMetaDataSGE.lastFragInvalidByteNum;
            let curInvalidByteNum      = tmpMergedMetaDataSGE.curInvalidByteNum;
            let isOnlySGE              = tmpMergedMetaDataSGE.isOnlySGE;
            let sgeIsFirst             = tmpMergedMetaDataSGE.sgeIsFirst;
            let sgeIsLast              = tmpMergedMetaDataSGE.sgeIsLast;
            let hasLessFrag            = tmpMergedMetaDataSGE.hasLessFrag;

            sgeIsOnlyReg   <= isOnlySGE;
            sgeIsLastReg   <= sgeIsLast;
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

            lastFragInvalidByteNumReg <= lastFragInvalidByteNum;

            curInvalidByteNumReg  <= nextHasLessFrag ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : 0;

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
            //     // ", curValidByteNumReg=%0d", curValidByteNumReg,
            //     ", curInvalidByteNumReg=%0d", curInvalidByteNumReg,
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
            let tmpMergedMetaDataSGE = mergedMetaDataQ4EachSGE.first;
            mergedMetaDataQ4EachSGE.deq;

            let lastFragInvalidByteNum = tmpMergedMetaDataSGE.lastFragInvalidByteNum;
            let curInvalidByteNum      = tmpMergedMetaDataSGE.curInvalidByteNum;
            let isOnlySGE              = tmpMergedMetaDataSGE.isOnlySGE;
            let sgeIsFirst             = tmpMergedMetaDataSGE.sgeIsFirst;
            let sgeIsLast              = tmpMergedMetaDataSGE.sgeIsLast;
            let hasLessFrag            = tmpMergedMetaDataSGE.hasLessFrag;

            sgeIsLastReg   <= sgeIsLast;
            hasLessFragReg <= hasLessFrag;

            lastFragInvalidByteNumReg <= lastFragInvalidByteNum;

            curInvalidByteNumReg <= curInvalidByteNum;

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
            //     // ", sumValidByteNum=%0d", sumValidByteNum,
            //     ", sumInvalidByteNum=%0d", sumInvalidByteNum,
            //     ", sumInvalidBitNum=%0d", sumInvalidBitNum,
            //     // ", curValidByteNum=%0d", curValidByteNum,
            //     ", curInvalidByteNum=%0d", curInvalidByteNum,
            //     // ", nextValidByteNum=%0d", nextValidByteNum,
            //     ", nextInvalidByteNum=%0d", nextInvalidByteNum,
            //     ", nextInvalidBitNum=%0d", nextInvalidBitNum
            // );
        endaction
    endfunction

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;

        mergedMetaDataQ4EachSGE.clear;
        payloadFragShiftQ.clear;

        stateReg <= MERGE_SGL_PAYLOAD_INIT;
    endrule

    rule handleMetaDataEachSGE if (!clearAll);
        let sgeMergedMetaData = sgeMergedMetaDataPipeIn.first;
        sgeMergedMetaDataPipeIn.deq;

        let isOnlySGE  = sgeMergedMetaData.isFirst && sgeMergedMetaData.isLast;
        let sgeIsFirst = sgeMergedMetaData.isFirst;
        let sgeIsLast  = sgeMergedMetaData.isLast;

        let lastFragValidByteNum = sgeMergedMetaData.lastFragValidByteNum;
        let lastFragInvalidByteNum = calcFragInvalidByteNum(lastFragValidByteNum);

        let curInvalidByteNum  =  0;
        let preInvalidByteNum = lastFragInvalidByteNum;

        let hasLessFrag = lastFragValidByteNum < fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        if (!sgeIsFirst) begin
            hasLessFrag = preInvalidByteNumReg >= lastFragValidByteNum;

            let sumInvalidByteNum = preInvalidByteNumReg + lastFragInvalidByteNum;

            curInvalidByteNum = preInvalidByteNumReg;

            preInvalidByteNum = sumInvalidByteNum & zeroExtend(busByteNumMask);
        end

        preInvalidByteNumReg <= preInvalidByteNum;

        let tmpMergedMetaDataSGE = TmpMergedMetaDataSGE {
            lastFragInvalidByteNum: lastFragInvalidByteNum,
            curInvalidByteNum     : curInvalidByteNum,
            isOnlySGE             : isOnlySGE,
            sgeIsFirst            : sgeIsFirst,
            sgeIsLast             : sgeIsLast,
            hasLessFrag           : hasLessFrag
        };
        mergedMetaDataQ4EachSGE.enq(tmpMergedMetaDataSGE);
    endrule

    rule mergePayloadInit if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_INIT);
        let nextPayloadFrag <- preprocessNextSGL;
        prePayloadFragReg <= nextPayloadFrag;
    endrule

    rule mergeFirstOrMidSGE if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_FIRST_OR_MID_SGE);
        let curPayloadFrag = sgeMergedPayloadPipeIn.first;
        sgeMergedPayloadPipeIn.deq;

        let shouldOutput = True;
        let nextPrePayloadFrag = curPayloadFrag;
        if (curPayloadFrag.isLast) begin
            preprocessNextSGE;

            nextPrePayloadFrag.isLast = False;
            nextPrePayloadFrag.data   = truncate({ prePayloadFragReg.data,   curPayloadFrag.data   } >> getFragEnBitNumByByteEnNum(zeroExtend(lastFragInvalidByteNumReg)));

            shouldOutput = !hasLessFragReg;
        end
        prePayloadFragReg <= nextPrePayloadFrag;

        if (shouldOutput) begin
            isFirstFragReg <= False;

            let prePayloadFrag = prePayloadFragReg;
            // In case prePayloadFragReg is emptyDataStream,
            // then it should set mergeFrag.isFirst as true.
            prePayloadFrag.isFirst = isFirstFragReg;
            prePayloadFrag.isLast = False;

            payloadFragShiftQ.enq(tuple3(
                prePayloadFrag, curPayloadFrag,
                curInvalidByteNumReg
            ));
        end
        // $display(
        //     "time=%0t: mergeFirstOrMidSGE", $time,
        //     ", shouldOutput=", fshow(shouldOutput),
        //     ", hasLessFragReg=", fshow(hasLessFragReg),
        //     ", curInvalidByteNumReg=%0d", curInvalidByteNumReg,
        //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
        //     // ", prePayloadFrag.isFirst=", fshow(prePayloadFrag.isFirst),
        //     // ", prePayloadFrag.isLast=", fshow(prePayloadFrag.isLast),
        //     // ", prePayloadFrag.byteEn=%h", prePayloadFrag.byteEn,
        //     ", nextPrePayloadFrag.isFirst=", fshow(nextPrePayloadFrag.isFirst),
        //     ", nextPrePayloadFrag.isLast=", fshow(nextPrePayloadFrag.isLast),
        //     ", nextPrePayloadFrag.byteEn=%h", nextPrePayloadFrag.byteEn
        // );
    endrule

    rule mergeLastOrOnlySGE if (!clearAll && stateReg == MERGE_SGL_PAYLOAD_LAST_OR_ONLY_SGE);
        let nextPayloadFrag = genEmptyDataStream;
        let outPayloadFrag = prePayloadFragReg;

        let isLastFrag = prePayloadFragReg.isLast;
        if (prePayloadFragReg.isLast) begin
            if (mergedMetaDataQ4EachSGE.notEmpty && sgeMergedPayloadPipeIn.notEmpty) begin
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

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isLast = isLastFrag;
        payloadFragShiftQ.enq(tuple3(
            prePayloadFrag, nextPayloadFrag,
            curInvalidByteNumReg
        ));
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

    rule shiftPayloadFrag if (!clearAll);
        let {
            prePayloadFrag, curPayloadFrag,
            leftShiftInvalidByteNum
        } = payloadFragShiftQ.first;
        payloadFragShiftQ.deq;

        let outPayloadFrag = leftShiftAndMergeFragData(
            prePayloadFrag, curPayloadFrag,
            truncate(leftShiftInvalidByteNum)
        );
        pktPayloadOutQ.enq(outPayloadFrag);
    //     $display(
    //         "time=%0t: shiftPayloadFrag @ mkMergePayloadAllSGE", $time,
    //         ", sgeIsOnlyReg=", fshow(sgeIsOnlyReg),
    //         ", hasLessFragReg=", fshow(hasLessFragReg),
    //         ", leftShiftInvalidByteNum=%0d", leftShiftInvalidByteNum,
    //         ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
    //         ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
    //         ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
    //         ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
    //         ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
    //         ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn,
    //         ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
    //         ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
    //         ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
    //     );
    endrule

    return toPipeOut(pktPayloadOutQ);
endmodule

// TODO: remove it 
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
    FIFOF#(Tuple7#(
        PMTU, PktFragNum, PktNum, ByteEnBitNum, Bool, Bool, Bool
    )) sglAdjustedPktMetaDataQ <- mkFIFOF;
    FIFOF#(Tuple5#(
        DataStream, DataStream, ByteEnBitNum, Bool, ByteEnBitNum
    )) payloadFragShiftQ <- mkFIFOF;


    // rule debug;
    //     if (!pktPayloadOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAdjustPayloadSegment pktPayloadOutQ");
    //     end
    //     if (!sglAdjustedPktMetaDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAdjustPayloadSegment sglAdjustedPktMetaDataQ");
    //     end
    //     if (!payloadFragShiftQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkAdjustPayloadSegment payloadFragShiftQ");
    //     end
    // endrule


    Reg#(DataStream) prePayloadFragReg <- mkRegU;

    Reg#(ByteEnBitNum) firstPktLastFragValidByteNumReg <- mkRegU;

    Reg#(Bool) isFirstPktReg    <- mkRegU;
    Reg#(Bool) hasExtraFragReg  <- mkRegU;
    Reg#(Bool) sglHasOnlyPktReg <- mkRegU;
    Reg#(Bool) noShiftFragReg   <- mkRegU;

    Reg#(PktFragNum) pmtuFragNumReg <- mkRegU;
    Reg#(PktFragNum) pktRemainingFragNumReg <- mkRegU;
    Reg#(PktNum) sglRemainingPktNumReg <- mkRegU;
    Reg#(AdjustPayloadSegmentState) stateReg <- mkReg(ADJUST_PAYLOAD_SEGMENT_INIT);

    function ActionValue#(DataStream) prepareNextSGL();
        actionvalue
            let {
                pmtu, firstPktFragNum, adjustedPktNum, firstPktLastFragValidByteNum,
                sglHasOnlyPkt, hasExtraFrag, noShiftFrag
            } = sglAdjustedPktMetaDataQ.first;
            sglAdjustedPktMetaDataQ.deq;

            pmtuFragNumReg <= calcFragNumByPMTU(pmtu);

            pktRemainingFragNumReg <= firstPktFragNum;
            sglRemainingPktNumReg  <= adjustedPktNum;

            firstPktLastFragValidByteNumReg <= firstPktLastFragValidByteNum;

            isFirstPktReg    <= True;
            hasExtraFragReg  <= hasExtraFrag;
            sglHasOnlyPktReg <= sglHasOnlyPkt;
            noShiftFragReg   <= noShiftFrag;

            if (sglHasOnlyPkt) begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT;
            end
            else begin
                stateReg <= ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT;
            end

            let curPayloadFrag = sglAllPayloadPipeIn.first;
            sglAllPayloadPipeIn.deq;

            // $display(
            //     "time=%0t: prepareNextSGL", $time,
            //     ", sglHasOnlyPkt=", fshow(sglHasOnlyPkt),
            //     ", hasExtraFrag=", fshow(hasExtraFrag),
            //     ", noShiftFrag=", fshow(noShiftFrag),
            //     // ", sgeMergedMetaData.isFirst=", fshow(sgeMergedMetaData.isFirst),
            //     // ", sgeMergedMetaData.isLast=", fshow(sgeMergedMetaData.isLast),
            //     ", firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
            //     ", adjustedPktNum=%0d", adjustedPktNum,
            //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
            //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
            //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn
            // );
            return curPayloadFrag;
        endactionvalue
    endfunction

    rule resetAndClear if (clearAll);
        pktPayloadOutQ.clear;

        sglAdjustedPktMetaDataQ.clear;
        payloadFragShiftQ.clear;

        stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
    endrule

    rule handleMetaDataEachSGL if (!clearAll);
        let adjustedTotalPayloadMeta = adjustedTotalPayloadMetaDataPipeIn.first;
        adjustedTotalPayloadMetaDataPipeIn.deq;

        let origLastFragValidByteNum     = adjustedTotalPayloadMeta.origLastFragValidByteNum;
        let firstPktLastFragValidByteNum = adjustedTotalPayloadMeta.firstPktLastFragValidByteNum;


        let sglHasOnlyPkt = isOneR(adjustedTotalPayloadMeta.adjustedPktNum);
        let hasExtraFrag  = firstPktLastFragValidByteNum < origLastFragValidByteNum;
        let noShiftFrag   = firstPktLastFragValidByteNum == fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        sglAdjustedPktMetaDataQ.enq(tuple7(
            adjustedTotalPayloadMeta.pmtu, adjustedTotalPayloadMeta.firstPktFragNum,
            adjustedTotalPayloadMeta.adjustedPktNum, firstPktLastFragValidByteNum,
            sglHasOnlyPkt, hasExtraFrag, noShiftFrag
        ));
    endrule

    rule adjustPayloadInit if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_INIT);
        let nextPrePayloadFrag <- prepareNextSGL;
        prePayloadFragReg <= nextPrePayloadFrag;
    endrule

    rule adjustFirstOrMidPkt if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_FIRST_OR_MID_PKT);
        let isAdjustedLastFrag = isOneR(pktRemainingFragNumReg);
        let curPayloadFrag = genEmptyDataStream;

        let shouldShiftPayloadFrag = !(isFirstPktReg || noShiftFragReg);
        if (prePayloadFragReg.isLast) begin
            immAssert(
                isOneR(pktRemainingFragNumReg) && isTwoR(sglRemainingPktNumReg),
                "pktRemainingFragNumReg and sglRemainingPktNumReg assertion @ mkAdjustPayloadSegment",
                $format(
                    "pktRemainingFragNumReg=%0d", pktRemainingFragNumReg,
                    " should be one, and sglRemainingPktNumReg=%0d", sglRemainingPktNumReg,
                    " should be two when prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
                    " and stateReg=", fshow(stateReg)
                )
            );
        end
        else begin
            curPayloadFrag = sglAllPayloadPipeIn.first;

            let nextPayloadFrag = curPayloadFrag;
            let isFirstPktAdjustedLastFrag = isFirstPktReg && isAdjustedLastFrag;
            if (noShiftFragReg || !isFirstPktAdjustedLastFrag) begin
                sglAllPayloadPipeIn.deq;
            end
            // if (!isFirstPktAdjustedLastFrag) begin
            //     sglAllPayloadPipeIn.deq;
            // end
            else begin
                // Do not dequeue when the last fragment of the first packet,
                // Since the queue head is the first fragment of the next packet,
                // So keep the last fragment of the first packet in prePayloadFragReg.
                nextPayloadFrag = prePayloadFragReg;
            end
            nextPayloadFrag.isFirst = isAdjustedLastFrag;
            prePayloadFragReg <= nextPayloadFrag;
        end

        let shouldChangeByteEn = False;
        if (isAdjustedLastFrag) begin
            if (isFirstPktReg) begin
                shouldChangeByteEn = True;
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

        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isLast = isAdjustedLastFrag;

        let leftShiftValidByteNum = firstPktLastFragValidByteNumReg;
        if (!shouldShiftPayloadFrag) begin
            leftShiftValidByteNum = 0;
        end
        payloadFragShiftQ.enq(tuple5(
            prePayloadFrag, curPayloadFrag,
            leftShiftValidByteNum,
            shouldChangeByteEn, firstPktLastFragValidByteNumReg
        ));
        // $display(
        //     "time=%0t: adjustFirstOrMidPkt", $time,
        //     ", hasExtraFragReg=", fshow(hasExtraFragReg),
        //     ", isAdjustedLastFrag=", fshow(isAdjustedLastFrag),
        //     ", noShiftFragReg=", fshow(noShiftFragReg),
        //     ", shouldShiftPayloadFrag=", fshow(shouldShiftPayloadFrag),
        //     ", pktRemainingFragNumReg=%0d", pktRemainingFragNumReg,
        //     ", sglRemainingPktNumReg=%0d", sglRemainingPktNumReg,
        //     ", firstPktLastFragValidByteNumReg=%0d", firstPktLastFragValidByteNumReg,
        //     ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
        //     ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
        //     ", prePayloadFragReg.byteEn=%h", prePayloadFragReg.byteEn,
        //     ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
        //     ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast),
        //     ", curPayloadFrag.byteEn=%h", curPayloadFrag.byteEn
        //     // ", outPayloadFrag.isFirst=", fshow(outPayloadFrag.isFirst),
        //     // ", outPayloadFrag.isLast=", fshow(outPayloadFrag.isLast),
        //     // ", outPayloadFrag.byteEn=%h", outPayloadFrag.byteEn
        // );
    endrule

    rule adjustLastOrOnlyPkt if (!clearAll && stateReg == ADJUST_PAYLOAD_SEGMENT_LAST_OR_ONLY_PKT);
        let nextPayloadFrag = genEmptyDataStream;

        let shouldShiftPayloadFrag = !(sglHasOnlyPktReg || noShiftFragReg);
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
            if (shouldShiftPayloadFrag && !hasExtraFragReg && nextPayloadFrag.isLast) begin
                // No extra fragment
                stateReg <= ADJUST_PAYLOAD_SEGMENT_INIT;
                isLastFrag = True;
            end
        end
        prePayloadFragReg <= nextPayloadFrag;

        immAssert(
            isOne(sglRemainingPktNumReg),
            "sglRemainingPktNumReg assertion @ mkAdjustPayloadSegment",
            $format(
                "sglRemainingPktNumReg=%0d", sglRemainingPktNumReg,
                " should be one when stateReg=", fshow(stateReg)
            )
        );

        let shouldChangeByteNum = False;
        let invalidByteNum = dontCareValue;
        let prePayloadFrag = prePayloadFragReg;
        prePayloadFrag.isLast = isLastFrag;

        let leftShiftValidByteNum = firstPktLastFragValidByteNumReg;
        if (!shouldShiftPayloadFrag) begin
            leftShiftValidByteNum = 0;
        end
        payloadFragShiftQ.enq(tuple5(
            prePayloadFrag, nextPayloadFrag,
            leftShiftValidByteNum,
            shouldChangeByteNum, invalidByteNum
        ));
        $display(
            "time=%0t: adjustLastOrOnlyPkt", $time,
            ", sglHasOnlyPktReg=", fshow(sglHasOnlyPktReg),
            ", hasExtraFragReg=", fshow(hasExtraFragReg),
            ", noShiftFragReg=", fshow(noShiftFragReg),
            ", shouldShiftPayloadFrag=", fshow(shouldShiftPayloadFrag),
            ", prePayloadFragReg.isFirst=", fshow(prePayloadFragReg.isFirst),
            ", prePayloadFragReg.isLast=", fshow(prePayloadFragReg.isLast),
            ", prePayloadFragReg.byteNum=%h", prePayloadFragReg.byteNum,
            ", prePayloadFrag.isFirst=", fshow(prePayloadFrag.isFirst),
            ", prePayloadFrag.isLast=", fshow(prePayloadFrag.isLast),
            ", prePayloadFrag.byteNum=%h", prePayloadFrag.byteNum,
            ", nextPayloadFrag.isFirst=", fshow(nextPayloadFrag.isFirst),
            ", nextPayloadFrag.isLast=", fshow(nextPayloadFrag.isLast),
            ", nextPayloadFrag.byteNum=%h", nextPayloadFrag.byteNum,

            ", leftShiftValidByteNum=", fshow(leftShiftValidByteNum),
            ", shouldChangeByteNum=", fshow(shouldChangeByteNum)
            // ", invalidByteNum=", fshow(invalidByteNum)
        );
    endrule

    rule shiftPayloadFrag if (!clearAll);
        let {
            prePayloadFrag, curPayloadFrag,
            leftShiftValidByteNum,
            shouldChangeByteNum, firstPktLastFragByteNum
        } = payloadFragShiftQ.first;
        payloadFragShiftQ.deq;

        immAssert(
            msb(leftShiftValidByteNum) != 1,
            "left shift value assertion @ mkAdjustPayloadSegment",
            $format(
                "leftShiftValidByteNum=%0d", leftShiftValidByteNum,
                " should not have MSB as one"
            )
        );

        let outPayloadFrag = prePayloadFrag;

        let sumWithCarryBit = {1'b0, outPayloadFrag.byteNum} + zeroExtend(curPayloadFrag.byteNum) - zeroExtend(leftShiftValidByteNum);
        outPayloadFrag.byteNum = sumWithCarryBit > fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) ? fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) : truncate(sumWithCarryBit);
        outPayloadFrag.data   = truncateLSB({ outPayloadFrag.data, curPayloadFrag.data } << getFragEnBitNumByByteEnNum(zeroExtend(leftShiftValidByteNum)));
        if (shouldChangeByteNum) begin
            outPayloadFrag.byteNum = firstPktLastFragByteNum;
        end
        pktPayloadOutQ.enq(outPayloadFrag);
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
    // WorkReqID         wrID; // TODO: remote it
    // QPN               sqpn; // TODO: remote it
    ScatterGatherList sgl;
    Length            totalLen;
    ADDR              raddr;
    PMTU              pmtu;
    Bool              addPadding;
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
    // Length totalLen;
    // ADDR   origRemoteAddr;
    // PMTU   pmtu;
    PktLen pmtuMask;
    PktLen addrAndLenLowPartSum;
    PktLen pmtuLen;
    PktLen lenLowPart;
    PktLen maxFirstPktLen;
    PktNum truncatedPktNum;
    ADDR   pmtuAlignedStartAddr;
    Bool   isZeroPayloadLen;
    // Bool   shouldAddPadding;
} TmpPayloadGenMetaData deriving(Bits);

typedef struct {
    ADDR        origRemoteAddr;
    ADDR        secondChunkStartAddr;
    Length      totalLen;
    PktNum      truncatedPktNum;
    PktNumAddOn pktNumAddOne;
    PktLen      lenLowPart;
    PktLen      maxFirstPktLen;
    PktLen      tmpLastPktLen;
    PktLen      pmtuLen;
    PMTU        pmtu;
    Bool        notFullPkt;
    Bool        hasExtraPkt;
    Bool        hasResidue;
    Bool        isZeroPayloadLen;
    Bool        shouldAddPadding;
} TmpAdjustFirstAndLastPktLen deriving(Bits);

typedef struct {
    ADDR   firstRemoteAddr;
    ADDR   secondRemoteAddr;
    Length totalLen;
    PktNum totalPktNum;
    PktLen firstPktLen;
    PktLen lastPktLen;
    PktLen pmtuLen;
    PMTU   pmtu;
    Bool   isZeroPayloadLen;
    Bool   shouldAddPadding;
} TmpAdjustTotalPayloadMetaData deriving(Bits);

typedef struct {
    ADDR                  firstRemoteAddr;
    ADDR                  secondRemoteAddr;
    PktLen                firstPktLen;
    PktLen                lastPktLen;
    PktLen                pmtuLen;
    ByteEnBitNum firstPktLastFragValidByteNumWithPadding;
    ByteEnBitNum lastPktLastFragValidByteNumWithPadding;
    PAD                   firstPktPadCnt;
    PAD                   lastPktPadCnt;
    PktNum                totalPktNum;
    PMTU                  pmtu;
    Bool                  isOnlyPkt;
    Bool                  isZeroPayloadLen;
    Bool                  shouldAddPadding;
} TmpPayloadGenRespDataStep1 deriving(Bits);

typedef struct {
    ADDR                  remoteAddr;
    PktLen                firstPktLen;
    PktLen                lastPktLen;
    PktLen                pmtuLen;
    PAD                   firstPktPadCnt;
    PAD                   lastPktPadCnt;
    Bool                  isFirstPkt;
    Bool                  isLastPkt;
    ByteEnBitNum firstPktLastFragValidByteNumWithPadding;
    ByteEnBitNum lastPktLastFragValidByteNumWithPadding;
    Bool                  isZeroPayloadLen;
    Bool                  shouldAddPadding;
} TmpPayloadGenRespDataStep2 deriving(Bits);

typedef struct {
    ByteEnBitNum       firstPktLastFragByteNumWithPadding;
    ByteEnBitNum       lastPktLastFragByteNumWithPadding;
    Bool                        isZeroPayloadLen;
    Bool                        shouldAddPaddingFirst;
    Bool                        shouldAddPaddingLast;
} TmpPaddingData deriving(Bits);

interface PayloadGenerator;
    interface Server#(PayloadGenReqSG, PayloadGenRespSG) srvPort;
    interface PipeOut#(PayloadGenTotalMetaData) totalMetaDataPipeOut;
    interface DataStreamPipeOut payloadDataStreamPipeOut;
    interface PipeOut#(PayloadMetaData) payloadMetaDataPipeOut;
    method Bool payloadNotEmpty();
endinterface

module mkPayloadGenerator#(
    Bool clearAll, DmaReadCntrl dmaReadCntrl
)(PayloadGenerator);
    FIFOF#(PayloadGenReqSG)                       payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadGenRespSG)                     payloadGenRespQ <- mkFIFOF;
    FIFOF#(PayloadGenTotalMetaData)            totalMetaDataOutQ <- mkFIFOF;
    FIFOF#(PayloadMetaData)                  payloadMetaDataOutQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(DataStream) sgePayloadOutQ <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadGenReqSG, TmpPayloadGenMetaData)) adjustReqPktLenQ <- mkFIFOF;
    FIFOF#(TmpAdjustFirstAndLastPktLen) adjustFirstAndLastPktLenQ <- mkFIFOF;
    FIFOF#(TmpAdjustTotalPayloadMetaData) adjustTotalPayloadMetaDataQ <- mkFIFOF;
    FIFOF#(TmpPayloadGenRespDataStep1) genPayloadRespStep1Q <- mkFIFOF;
    FIFOF#(TmpPayloadGenRespDataStep2) genPayloadRespStep2Q <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadGenRespSG, TmpPaddingData)) addPaddingDataQ <- mkSizedFIFOF(10);
    FIFOF#(AdjustedTotalPayloadMetaData) adjustedTotalPayloadMetaDataQ <- mkFIFOF;
    FIFOF#(DataStream) bramQueueTimingFixStageQ <- mkFIFOF;





`ifdef SUPPORT_SGL
    let sgeMergedPayloadPipeOut <- mkMergePayloadEachSGE(
        clearAll, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );
    let sglMergedPayloadPipeOut <- mkMergePayloadAllSGE(
        clearAll, dmaReadCntrl.sgeMergedMetaDataPipeOut, sgeMergedPayloadPipeOut
    );
    let adjustedPayloadPipeOut <- mkAdjustPayloadSegment(
        clearAll, toPipeOut(adjustedTotalPayloadMetaDataQ), sglMergedPayloadPipeOut
    );
`else
    let sgeMergedPayloadPipeOut <- mkMergePayloadEachSGE(
        clearAll, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );
    let adjustedPayloadPipeOut <- mkAdjustPayloadSegment(
        clearAll, toPipeOut(adjustedTotalPayloadMetaDataQ), sgeMergedPayloadPipeOut
    );
`endif



    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let bramQ2PipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);
    let payloadBufPipeOut = bramQ2PipeOut.pipeOut;

    Reg#(ADDR)     pktRemoteAddrReg <- mkRegU;
    Reg#(Bool)        isFirstPktReg <- mkReg(True);
    Reg#(PktNum) remainingPktNumReg <- mkRegU;


    // rule debug;
    //     if (!payloadGenReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator payloadGenReqQ");
    //     end
    //     if (!payloadGenRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator payloadGenRespQ");
    //     end
    //     if (!totalMetaDataOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator totalMetaDataOutQ");
    //     end
    //     if (!sgePayloadOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator sgePayloadOutQ");
    //     end
    //     if (!adjustReqPktLenQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator adjustReqPktLenQ");
    //     end
    //     if (!adjustFirstAndLastPktLenQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator adjustFirstAndLastPktLenQ");
    //     end
    //     if (!adjustTotalPayloadMetaDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator adjustTotalPayloadMetaDataQ");
    //     end
    //     if (!genPayloadRespStep1Q.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator genPayloadRespStep1Q");
    //     end
    //     if (!addPaddingDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator addPaddingDataQ");
    //     end
    //     if (!adjustedTotalPayloadMetaDataQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator adjustedTotalPayloadMetaDataQ");
    //     end
    //     if (!payloadBufQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPayloadGenerator payloadBufQ");
    //     end
        
    // endrule

    rule resetAndClear if (clearAll);
        payloadGenReqQ.clear;
        payloadGenRespQ.clear;
        totalMetaDataOutQ.clear;

        sgePayloadOutQ.clear;
        adjustReqPktLenQ.clear;
        adjustFirstAndLastPktLenQ.clear;
        adjustTotalPayloadMetaDataQ.clear;
        genPayloadRespStep1Q.clear;
        addPaddingDataQ.clear;
        adjustedTotalPayloadMetaDataQ.clear;

        payloadBufQ.clear;
        bramQ2PipeOut.clear;
        bramQueueTimingFixStageQ.clear;

        // remainingPktNumReg <= 0;
        isFirstPktReg <= True;
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

        let {
            pmtuMask, addrAndLenLowPartSum, pmtuLen, lenLowPart,
            maxFirstPktLen, truncatedPktNum, pmtuAlignedStartAddr
        } = stepOneCalcPktNumAndPktLenByAddrAndPMTU(
            payloadGenReq.raddr, payloadGenReq.totalLen, payloadGenReq.pmtu
        );

        let tmpPayloadGenMetaData = TmpPayloadGenMetaData {
            pmtuMask            : pmtuMask,
            addrAndLenLowPartSum: addrAndLenLowPartSum,
            pmtuLen             : pmtuLen,
            lenLowPart          : lenLowPart,
            maxFirstPktLen      : maxFirstPktLen,
            truncatedPktNum     : truncatedPktNum,
            pmtuAlignedStartAddr: pmtuAlignedStartAddr,
            isZeroPayloadLen    : isZeroPayloadLen
        };
        adjustReqPktLenQ.enq(tuple2(payloadGenReq, tmpPayloadGenMetaData));
        // $display(
        //     "time=%0t: mkPayloadGenerator recvReq", $time,
        //     // ", payloadGenReq=", fshow(payloadGenReq),
        //     ", isZeroPayloadLen=", fshow(isZeroPayloadLen)
        // );
    endrule

    rule recvDmaReadCntrlResp if (!clearAll);
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        sgePayloadOutQ.enq(dmaReadCntrlResp.dmaReadResp.dataStream);
        // $display("time=%0t: recvDmaReadCntrlResp", $time);
    endrule

    rule issueDmaReadCntrlReq if (!clearAll);
        let { payloadGenReq, tmpPayloadGenMetaData } = adjustReqPktLenQ.first;
        adjustReqPktLenQ.deq;
        let pmtuMask             = tmpPayloadGenMetaData.pmtuMask;
        let addrAndLenLowPartSum = tmpPayloadGenMetaData.addrAndLenLowPartSum;
        let pmtuLen              = tmpPayloadGenMetaData.pmtuLen;
        let lenLowPart           = tmpPayloadGenMetaData.lenLowPart;
        let maxFirstPktLen       = tmpPayloadGenMetaData.maxFirstPktLen;
        let truncatedPktNum      = tmpPayloadGenMetaData.truncatedPktNum;
        let pmtuAlignedStartAddr = tmpPayloadGenMetaData.pmtuAlignedStartAddr;
        let isZeroPayloadLen     = tmpPayloadGenMetaData.isZeroPayloadLen;

        if (!isZeroPayloadLen) begin
            let dmaReadCntrlReq = DmaReadCntrlReq {
                sglDmaReadMetaData: DmaReadMetaDataSGL {
                    sgl           : payloadGenReq.sgl,
                    totalLen      : payloadGenReq.totalLen
                },
                pmtu              : payloadGenReq.pmtu
            };
            dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);
        end

        let {
            secondChunkStartAddr, tmpLastPktLen, pktNumAddOne,
            notFullPkt, hasExtraPkt, hasResidue
        } = stepTwoCalcPktNumAndPktLenByAddrAndPMTU(
            pmtuAlignedStartAddr, payloadGenReq.pmtu, pmtuMask,
            addrAndLenLowPartSum, truncatedPktNum
        );

        let tmpAdjustFirstAndLastPktLen = TmpAdjustFirstAndLastPktLen {
            origRemoteAddr      : payloadGenReq.raddr,
            secondChunkStartAddr: secondChunkStartAddr,
            totalLen            : payloadGenReq.totalLen,
            truncatedPktNum     : truncatedPktNum,
            pktNumAddOne        : pktNumAddOne,
            lenLowPart          : lenLowPart,
            maxFirstPktLen      : maxFirstPktLen,
            tmpLastPktLen       : tmpLastPktLen,
            pmtuLen             : pmtuLen,
            pmtu                : payloadGenReq.pmtu,
            notFullPkt          : notFullPkt,
            hasExtraPkt         : hasExtraPkt,
            hasResidue          : hasResidue,
            isZeroPayloadLen    : isZeroPayloadLen,
            shouldAddPadding    : payloadGenReq.addPadding
        };
        adjustFirstAndLastPktLenQ.enq(tmpAdjustFirstAndLastPktLen);
    endrule

    rule adjustFirstAndLastPktLen if (!clearAll);
        let tmpAdjustFirstAndLastPktLen = adjustFirstAndLastPktLenQ.first;
        adjustFirstAndLastPktLenQ.deq;

        let origRemoteAddr       = tmpAdjustFirstAndLastPktLen.origRemoteAddr;
        let secondChunkStartAddr = tmpAdjustFirstAndLastPktLen.secondChunkStartAddr;
        let totalLen             = tmpAdjustFirstAndLastPktLen.totalLen;
        let truncatedPktNum      = tmpAdjustFirstAndLastPktLen.truncatedPktNum;
        let pktNumAddOne         = tmpAdjustFirstAndLastPktLen.pktNumAddOne;
        let lenLowPart           = tmpAdjustFirstAndLastPktLen.lenLowPart;
        let maxFirstPktLen       = tmpAdjustFirstAndLastPktLen.maxFirstPktLen;
        let tmpLastPktLen        = tmpAdjustFirstAndLastPktLen.tmpLastPktLen;
        let pmtuLen              = tmpAdjustFirstAndLastPktLen.pmtuLen;
        let pmtu                 = tmpAdjustFirstAndLastPktLen.pmtu;
        let notFullPkt           = tmpAdjustFirstAndLastPktLen.notFullPkt;
        let hasExtraPkt          = tmpAdjustFirstAndLastPktLen.hasExtraPkt;
        let hasResidue           = tmpAdjustFirstAndLastPktLen.hasResidue;
        let isZeroPayloadLen     = tmpAdjustFirstAndLastPktLen.isZeroPayloadLen;
        let shouldAddPadding     = tmpAdjustFirstAndLastPktLen.shouldAddPadding;

        let {
            firstPktLen, lastPktLen, totalPktNum
        } = stepThreeCalcPktNumAndPktLenByAddrAndPMTU(
            truncatedPktNum, pktNumAddOne, lenLowPart, maxFirstPktLen,
            tmpLastPktLen, pmtuLen, notFullPkt, hasExtraPkt, hasResidue
        );
        if (!isZeroPayloadLen) begin
            immAssert(
                !isZero(firstPktLen) && !isZero(lastPktLen),
                "firstPktLen lastPktLen assertion @ mkPayloadGenerator",
                $format(
                    "firstPktLen=%0d", firstPktLen,
                    " and lastPktLen=%0d", lastPktLen,
                    " should not be zero, when totalLen=%0d", totalLen,
                    ", lenLowPart=%0d", lenLowPart,
                    ", maxFirstPktLen=%0d", maxFirstPktLen,
                    ", tmpLastPktLen=%0d", tmpLastPktLen,
                    ", origRemoteAddr=%h", origRemoteAddr,
                    ", pmtu=", fshow(pmtu),
                    ", notFullPkt=", fshow(notFullPkt),
                    ", hasExtraPkt=", fshow(hasExtraPkt),
                    ", hasResidue=", fshow(hasResidue)
                )
            );
        end

        let adjustTotalPayloadMetaData = TmpAdjustTotalPayloadMetaData {
            firstRemoteAddr : origRemoteAddr,
            secondRemoteAddr: secondChunkStartAddr,
            totalLen        : totalLen,
            totalPktNum     : totalPktNum,
            firstPktLen     : firstPktLen,
            lastPktLen      : lastPktLen,
            pmtuLen         : pmtuLen,
            pmtu            : pmtu,
            isZeroPayloadLen: isZeroPayloadLen,
            shouldAddPadding: shouldAddPadding
        };
        adjustTotalPayloadMetaDataQ.enq(adjustTotalPayloadMetaData);
        // $display(
        //     "time=%0t: mkPayloadGenerator issueDmaReqAndAdjustFirstAndLastPktLen", $time,
        //     // ", payloadGenReq=", fshow(payloadGenReq),
        //     ", origRemoteAddr=%h", origRemoteAddr,
        //     ", totalLen=%0d", totalLen,
        //     ", pmtu=", fshow(pmtu),
        //     ", isZeroPayloadLen=", fshow(isZeroPayloadLen)
        // );
    endrule

    rule calcAdjustedTotalPayloadMetaData if (!clearAll);
        let adjustTotalPayloadMetaData = adjustTotalPayloadMetaDataQ.first;
        adjustTotalPayloadMetaDataQ.deq;

        let firstRemoteAddr  = adjustTotalPayloadMetaData.firstRemoteAddr;
        let secondRemoteAddr = adjustTotalPayloadMetaData.secondRemoteAddr;
        let totalLen         = adjustTotalPayloadMetaData.totalLen;
        let totalPktNum      = adjustTotalPayloadMetaData.totalPktNum;
        let firstPktLen      = adjustTotalPayloadMetaData.firstPktLen;
        let lastPktLen       = adjustTotalPayloadMetaData.lastPktLen;
        let pmtuLen          = adjustTotalPayloadMetaData.pmtuLen;
        let pmtu             = adjustTotalPayloadMetaData.pmtu;
        let isZeroPayloadLen = adjustTotalPayloadMetaData.isZeroPayloadLen;
        let shouldAddPadding = adjustTotalPayloadMetaData.shouldAddPadding;

        let origLastFragValidByteNum     = calcLastFragValidByteNum(totalLen);
        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(firstPktLen);
        let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(lastPktLen);
        let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        let firstPktPadCnt  = calcPadCnt(firstPktLen);
        let lastPktPadCnt   = calcPadCnt(lastPktLen);
        let isOnlyPkt       = isLessOrEqOneR(totalPktNum);

        let firstPktLastFragValidByteNumWithPadding = firstPktLastFragValidByteNum + zeroExtend(firstPktPadCnt);
        let lastPktLastFragValidByteNumWithPadding  = lastPktLastFragValidByteNum  + zeroExtend(lastPktPadCnt);
        immAssert(
            (fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - zeroExtend(firstPktPadCnt) >= firstPktLastFragValidByteNum) &&
            (fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) - zeroExtend(lastPktPadCnt)  >= lastPktLastFragValidByteNum),
            "padding assertion @ mkPayloadGenerator",
            $format(
                "firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
                " + firstPktPadCnt=%0d", firstPktPadCnt,
                " should not > DATA_BUS_BYTE_WIDTH=%0d", valueOf(DATA_BUS_BYTE_WIDTH),
                ", and lastPktLastFragValidByteNum=%0d", lastPktLastFragValidByteNum,
                " + lastPktPadCnt=%0d", lastPktPadCnt,
                " should not > DATA_BUS_BYTE_WIDTH s=%0d", valueOf(DATA_BUS_BYTE_WIDTH)
            )
        );

        let adjustedTotalPayloadMetaData = AdjustedTotalPayloadMetaData {
            firstPktLen                  : firstPktLen,
            firstPktFragNum              : firstPktFragNum,
            firstPktLastFragValidByteNum : firstPktLastFragValidByteNum,
            origLastFragValidByteNum     : origLastFragValidByteNum,
            adjustedPktNum               : totalPktNum,
            pmtu                         : pmtu
        };
        if (!isZeroPayloadLen) begin
            adjustedTotalPayloadMetaDataQ.enq(adjustedTotalPayloadMetaData);
        end

        let tmpPayloadGenRespData = TmpPayloadGenRespDataStep1 {
            firstRemoteAddr                        : firstRemoteAddr,
            secondRemoteAddr                       : secondRemoteAddr,
            firstPktLen                            : firstPktLen,
            lastPktLen                             : lastPktLen,
            pmtuLen                                : pmtuLen,
            firstPktLastFragValidByteNumWithPadding: firstPktLastFragValidByteNumWithPadding,
            lastPktLastFragValidByteNumWithPadding : lastPktLastFragValidByteNumWithPadding,
            firstPktPadCnt                         : firstPktPadCnt,
            lastPktPadCnt                          : lastPktPadCnt,
            totalPktNum                            : totalPktNum,
            pmtu                                   : pmtu,
            isOnlyPkt                              : isOnlyPkt,
            isZeroPayloadLen                       : isZeroPayloadLen,
            shouldAddPadding                       : shouldAddPadding
        };
        genPayloadRespStep1Q.enq(tmpPayloadGenRespData);

        let totalMetaData = PayloadGenTotalMetaData {
            totalPktNum     : totalPktNum,
            isOnlyPkt       : isOnlyPkt,
            isZeroPayloadLen: isZeroPayloadLen
        };
        totalMetaDataOutQ.enq(totalMetaData);
        // $display(
        //     "time=%0t: mkPayloadGenerator calcAdjustedTotalPayloadMetaData", $time,
        //     // ", adjustedTotalPayloadMetaData=", fshow(adjustedTotalPayloadMetaData),
        //     ", firstRemoteAddr=%h", firstRemoteAddr,
        //     ", totalLen=%0d", totalLen,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen,
        //     ", pmtu=", fshow(pmtu),
        //     ", isZeroPayloadLen=", fshow(isZeroPayloadLen)
        // );
    endrule

    rule genPayloadGenRespStep1 if (!clearAll);
        let tmpPayloadGenRespData = genPayloadRespStep1Q.first;

        let firstRemoteAddr                         = tmpPayloadGenRespData.firstRemoteAddr;
        let secondRemoteAddr                        = tmpPayloadGenRespData.secondRemoteAddr;
        let firstPktLen                             = tmpPayloadGenRespData.firstPktLen;
        let lastPktLen                              = tmpPayloadGenRespData.lastPktLen;
        let pmtuLen                                 = tmpPayloadGenRespData.pmtuLen;
        let firstPktLastFragValidByteNumWithPadding = tmpPayloadGenRespData.firstPktLastFragValidByteNumWithPadding;
        let lastPktLastFragValidByteNumWithPadding  = tmpPayloadGenRespData.lastPktLastFragValidByteNumWithPadding;
        let firstPktPadCnt                          = tmpPayloadGenRespData.firstPktPadCnt;
        let lastPktPadCnt                           = tmpPayloadGenRespData.lastPktPadCnt;
        let totalPktNum                             = tmpPayloadGenRespData.totalPktNum;
        let pmtu                                    = tmpPayloadGenRespData.pmtu;
        let isOnlyPkt                               = tmpPayloadGenRespData.isOnlyPkt;
        let isZeroPayloadLen                        = tmpPayloadGenRespData.isZeroPayloadLen;
        let shouldAddPadding                        = tmpPayloadGenRespData.shouldAddPadding;

        let oneAsPSN   = 1;
        let remoteAddr = firstRemoteAddr;
        let nextRemoteAddr  = pktRemoteAddrReg;
        let remainingPktNum = remainingPktNumReg;
        if (isFirstPktReg) begin
            nextRemoteAddr = secondRemoteAddr;

            if (isOnlyPkt) begin
                remainingPktNum = 1;
            end
            else begin
                remainingPktNum = totalPktNum - 1;
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
        let isLastPkt  = isOnlyPkt || (!isFirstPktReg && remainingPktNumReg == 1);
        

        isFirstPktReg      <= isLastPkt;
        pktRemoteAddrReg   <= nextRemoteAddr;
        remainingPktNumReg <= remainingPktNum;

        if (isLastPkt) begin
            genPayloadRespStep1Q.deq;
        end

        genPayloadRespStep2Q.enq(TmpPayloadGenRespDataStep2{
            remoteAddr                              :   remoteAddr,
            firstPktLen                             :   firstPktLen,
            lastPktLen                              :   lastPktLen,
            pmtuLen                                 :   pmtuLen,
            firstPktPadCnt                          :   firstPktPadCnt,
            lastPktPadCnt                           :   lastPktPadCnt,
            isFirstPkt                              :   isFirstPkt,
            isLastPkt                               :   isLastPkt,
            firstPktLastFragValidByteNumWithPadding :   firstPktLastFragValidByteNumWithPadding,
            lastPktLastFragValidByteNumWithPadding  :   lastPktLastFragValidByteNumWithPadding,
            isZeroPayloadLen                        :   isZeroPayloadLen,
            shouldAddPadding                        :   shouldAddPadding
        });

    endrule

    rule genPayloadGenRespStep2 if (!clearAll);

        let tmpPayloadGenRespData = genPayloadRespStep2Q.first;
        genPayloadRespStep2Q.deq;

        let shouldAddPadding = tmpPayloadGenRespData.shouldAddPadding;
        let remoteAddr = tmpPayloadGenRespData.remoteAddr;
        let isFirstPkt = tmpPayloadGenRespData.isFirstPkt;
        let isLastPkt = tmpPayloadGenRespData.isLastPkt;
        let firstPktLastFragValidByteNumWithPadding = tmpPayloadGenRespData.firstPktLastFragValidByteNumWithPadding;
        let lastPktLastFragValidByteNumWithPadding = tmpPayloadGenRespData.lastPktLastFragValidByteNumWithPadding;
        let isZeroPayloadLen = tmpPayloadGenRespData.isZeroPayloadLen;
        let firstPktPadCnt = tmpPayloadGenRespData.firstPktPadCnt;
        let lastPktPadCnt = tmpPayloadGenRespData.lastPktPadCnt;
        let firstPktLen = tmpPayloadGenRespData.firstPktLen;
        let lastPktLen = tmpPayloadGenRespData.lastPktLen;
        let pmtuLen = tmpPayloadGenRespData.pmtuLen;

        let padCnt = shouldAddPadding ? (isFirstPkt ? firstPktPadCnt : (isLastPkt ? lastPktPadCnt : 0)) : 0;

        let pktLen = isFirstPkt ? firstPktLen    : (isLastPkt ? lastPktLen : pmtuLen);

        let payloadGenResp = PayloadGenRespSG {
            raddr           : remoteAddr,
            pktLen          : pktLen,
            padCnt          : padCnt,
            isFirst         : isFirstPkt,
            isLast          : isLastPkt
        };

        let tmpPaddingData = TmpPaddingData {
            firstPktLastFragByteNumWithPadding      : firstPktLastFragValidByteNumWithPadding,
            lastPktLastFragByteNumWithPadding       : lastPktLastFragValidByteNumWithPadding,
            isZeroPayloadLen                       : isZeroPayloadLen,
            shouldAddPaddingFirst                  : shouldAddPadding && isFirstPkt,
            shouldAddPaddingLast                   : shouldAddPadding && isLastPkt
        };
        addPaddingDataQ.enq(tuple2(payloadGenResp, tmpPaddingData));

        if (isZeroPayloadLen) begin
            immAssert(
                isZero(pktLen) && isZero(padCnt),
                "pktLen padCnt assertion @ mkPayloadGenerator",
                $format(
                    "pktLen=%0d", pktLen,
                    " and padCnt=%0d", padCnt,
                    " should both be zero when isZeroPayloadLen=", fshow(isZeroPayloadLen)
                )
            );
        end

        // $display(
        //     "time=%0t: genPayloadGenRespStep2", $time,
        //     ", payloadGenResp=", fshow(payloadGenResp),
        //     ", isFirstPkt=", fshow(isFirstPkt),
        //     ", isLastPkt=", fshow(isLastPkt),
        //     ", isOnlyPkt=", fshow(isOnlyPkt),
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", remainingPktNum=%0d", remainingPktNum,
        //     ", remainingPktNumReg=%0d", remainingPktNumReg
        // );
    endrule

    rule outputAndAddPadding if (!clearAll);
        let { payloadGenResp, tmpPaddingData } = addPaddingDataQ.first;

        let firstPktLastFragByteNumWithPadding = tmpPaddingData.firstPktLastFragByteNumWithPadding;
        let lastPktLastFragByteNumWithPadding  = tmpPaddingData.lastPktLastFragByteNumWithPadding;
        let isZeroPayloadLen = tmpPaddingData.isZeroPayloadLen;

        let isFirstPkt = payloadGenResp.isFirst;
        let isLastPkt  = payloadGenResp.isLast;
        if (isZeroPayloadLen) begin
            addPaddingDataQ.deq;
            payloadGenRespQ.enq(payloadGenResp);

            immAssert(
                isFirstPkt && isLastPkt,
                "isZeroPayloadLen assertion @ mkPayloadGenerator",
                $format(
                    "isFirstPkt=", fshow(isFirstPkt),
                    " and isLastPkt=", fshow(isLastPkt),
                    " should both be true when isZeroPayloadLen=", fshow(isZeroPayloadLen)
                )
            );
        end
        else begin
            let curPayloadFrag = adjustedPayloadPipeOut.first;
            adjustedPayloadPipeOut.deq;

            if (curPayloadFrag.isFirst) begin
                BusByteWidthMask maskedPacketLen = truncate(payloadGenResp.pktLen + zeroExtend(payloadGenResp.padCnt));
                let lastFragValidByteNum = zeroExtend(maskedPacketLen);
                if (isZero(maskedPacketLen)) begin
                    lastFragValidByteNum = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                end
                payloadMetaDataOutQ.enq(PayloadMetaData{
                    lastFragValidByteNum: lastFragValidByteNum
                });
            end

            // Generate response by the end of the payload
            // Every segmented payload has a payloadGenResp
            if (curPayloadFrag.isLast) begin
                if (tmpPaddingData.shouldAddPaddingFirst) begin
                    curPayloadFrag.byteNum = firstPktLastFragByteNumWithPadding;
                    $display(
                        "time=%0t: outputAndAddPadding", $time,
                        ", change curPayloadFrag.byteNum to firstPktLastFragByteNumWithPadding=", fshow(firstPktLastFragByteNumWithPadding)
                    );
                end
                else if (tmpPaddingData.shouldAddPaddingLast) begin
                    curPayloadFrag.byteNum = lastPktLastFragByteNumWithPadding;
                    $display(
                        "time=%0t: outputAndAddPadding", $time,
                        ", change curPayloadFrag.byteNum to lastPktLastFragByteNumWithPadding=", fshow(lastPktLastFragByteNumWithPadding)
                    );
                end
                addPaddingDataQ.deq;
                payloadGenRespQ.enq(payloadGenResp);
                // $display(
                //     "time=%0t: outputAndAddPadding", $time,
                //     ", payloadGenResp=", fshow(payloadGenResp)
                // );
            end
            bramQueueTimingFixStageQ.enq(curPayloadFrag);

            let isLastFragInFirstPkt = curPayloadFrag.isLast && isFirstPkt;
            let isLastFragInLastPkt  = curPayloadFrag.isLast && isLastPkt;
            $display(
                "time=%0t: outputAndAddPadding", $time,
                ", remainingPktNumReg=%0d", remainingPktNumReg,
                ", isFirstPktReg=", fshow(isFirstPktReg),
                ", isLastFragInFirstPkt=", fshow(isLastFragInFirstPkt),
                ", isLastFragInLastPkt=", fshow(isLastFragInLastPkt),
                ", isFirstPkt=", fshow(isFirstPkt),
                ", isLastPkt=", fshow(isLastPkt),
                ", curPayloadFrag.isFirst=", fshow(curPayloadFrag.isFirst),
                ", curPayloadFrag.isLast=", fshow(curPayloadFrag.isLast)
            );
        end
    endrule

    rule storeToOutputBramQueue if (!clearAll);
        // The BRAM FIFO is a lot complex than simple FIFO, so enq into it need
        // more time
        bramQueueTimingFixStageQ.deq;
        payloadBufQ.enq(bramQueueTimingFixStageQ.first);
    endrule

    interface srvPort = toGPServer(payloadGenReqQ, payloadGenRespQ);
    interface totalMetaDataPipeOut = toPipeOut(totalMetaDataOutQ);
    interface payloadDataStreamPipeOut = payloadBufPipeOut;
    interface payloadMetaDataPipeOut = toPipeOut(payloadMetaDataOutQ);
    method Bool payloadNotEmpty() = bramQ2PipeOut.notEmpty;
endmodule
