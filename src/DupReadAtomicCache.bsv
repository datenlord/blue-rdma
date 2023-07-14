import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

// import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

// The start address of the last read response packet,
// without the lower bits within PMTU width.
typedef Bit#(PKT_NUM_WIDTH) ReadRespLastPktAddrPart;

function Tuple5#(
    Bool, Bool, Bool, ReadRespLastPktAddrPart, ReadRespLastPktAddrPart
) computeReadEndAddrAndCompare(PMTU pmtu, RETH dupReadReth, RETH origReadReth) provisos(
    Add#(RDMA_MAX_LEN_WIDTH, RDMA_MAX_LEN_WIDTH, ADDR_WIDTH)
);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrHighHalf = truncateLSB(dupReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrHighHalf = truncateLSB(origReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrLowHalf  = truncate(dupReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrLowHalf  = truncate(origReadReth.va);

    // 32-bit comparison
    let addrHighHalfMatch = dAddrHighHalf == oAddrHighHalf;

    let { addrLowHalfMatch, readLenMatch, dupReadLastPktAddrPart, origReadLastPktAddrPart } = case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) oAddrLowPart = truncateLSB(oAddrLowHalf);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) dupLenPart  = truncateLSB(dupReadReth.dlen);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 8)) origLenPart = truncateLSB(origReadReth.dlen);

            // 25-bit addition and comparison, for end address match
            ReadRespLastPktAddrPart dupReadLastPktAddrPart  = zeroExtend({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart });
            ReadRespLastPktAddrPart origReadLastPktAddrPart = zeroExtend({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart });
            tuple4(
                dAddrLowHalf[7 : 0] == oAddrLowHalf[7 : 0] && dupReadReth.dlen[7 : 0] == origReadReth.dlen[7 : 0],
                origLenPart >= dupLenPart,
                dupReadLastPktAddrPart,
                origReadLastPktAddrPart
            );
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) oAddrLowPart = truncateLSB(oAddrLowHalf);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) dupLenPart  = truncateLSB(dupReadReth.dlen);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 9)) origLenPart = truncateLSB(origReadReth.dlen);

            // 24-bit addition and comparison, for end address match
            ReadRespLastPktAddrPart dupReadLastPktAddrPart  = zeroExtend({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart });
            ReadRespLastPktAddrPart origReadLastPktAddrPart = zeroExtend({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart });
            tuple4(
                dAddrLowHalf[8 : 0] == oAddrLowHalf[8 : 0] && dupReadReth.dlen[8 : 0] == origReadReth.dlen[8 : 0],
                origLenPart >= dupLenPart,
                dupReadLastPktAddrPart,
                origReadLastPktAddrPart
            );
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) oAddrLowPart = truncateLSB(oAddrLowHalf);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) dupLenPart  = truncateLSB(dupReadReth.dlen);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 10)) origLenPart = truncateLSB(origReadReth.dlen);

            // 23-bit addition and comparison, for end address match
            ReadRespLastPktAddrPart dupReadLastPktAddrPart  = zeroExtend({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart });
            ReadRespLastPktAddrPart origReadLastPktAddrPart = zeroExtend({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart });
            tuple4(
                dAddrLowHalf[9 : 0] == oAddrLowHalf[9 : 0] && dupReadReth.dlen[9 : 0] == origReadReth.dlen[9 : 0],
                origLenPart >= dupLenPart,
                dupReadLastPktAddrPart,
                origReadLastPktAddrPart
            );
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) oAddrLowPart = truncateLSB(oAddrLowHalf);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) dupLenPart  = truncateLSB(dupReadReth.dlen);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 11)) origLenPart = truncateLSB(origReadReth.dlen);

            // 22-bit addition and comparison, for end address match
            ReadRespLastPktAddrPart dupReadLastPktAddrPart  = zeroExtend({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart });
            ReadRespLastPktAddrPart origReadLastPktAddrPart = zeroExtend({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart });
            tuple4(
                dAddrLowHalf[10 : 0] == oAddrLowHalf[10 : 0] && dupReadReth.dlen[10 : 0] == origReadReth.dlen[10 : 0],
                origLenPart >= dupLenPart,
                dupReadLastPktAddrPart,
                origReadLastPktAddrPart
            );
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) oAddrLowPart = truncateLSB(oAddrLowHalf);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) dupLenPart  = truncateLSB(dupReadReth.dlen);
            Bit#(TSub#(RDMA_MAX_LEN_WIDTH, 12)) origLenPart = truncateLSB(origReadReth.dlen);

            // 21-bit addition and comparison, for end address match
            ReadRespLastPktAddrPart dupReadLastPktAddrPart  = zeroExtend({ 1'b0, dAddrLowPart } + { 1'b0, dupLenPart });
            ReadRespLastPktAddrPart origReadLastPktAddrPart = zeroExtend({ 1'b0, oAddrLowPart } + { 1'b0, origLenPart });
            tuple4(
                dAddrLowHalf[11 : 0] == oAddrLowHalf[11 : 0] && dupReadReth.dlen[11 : 0] == origReadReth.dlen[11 : 0],
                origLenPart >= dupLenPart,
                dupReadLastPktAddrPart,
                origReadLastPktAddrPart
            );
        end
    endcase;

    return tuple5(
        addrHighHalfMatch, addrLowHalfMatch, readLenMatch,
        dupReadLastPktAddrPart, origReadLastPktAddrPart
    );
endfunction

function ADDR getVerifiedDupReadAddr(RETH dupReadReth, RETH origReadReth) provisos(
    Add#(RDMA_MAX_LEN_WIDTH, RDMA_MAX_LEN_WIDTH, ADDR_WIDTH)
);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrHighHalf = truncateLSB(origReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrLowHalf  = truncate(dupReadReth.va);

    return { oAddrHighHalf, dAddrLowHalf };
endfunction

// Only compare the lower half of read request addresses
function Bool compareDupReadAddr(
    PMTU pmtu, RETH dupReadReth, RETH origReadReth
) provisos(
    Add#(RDMA_MAX_LEN_WIDTH, RDMA_MAX_LEN_WIDTH, ADDR_WIDTH)
);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrHighHalf = truncateLSB(dupReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrHighHalf = truncateLSB(origReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) dAddrLowHalf  = truncate(dupReadReth.va);
    Bit#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH)) oAddrLowHalf  = truncate(origReadReth.va);

    let addrMatch = case (pmtu)
        IBV_MTU_256 : begin
            // 8 = log2(256)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 8)) oAddrLowPart = truncateLSB(oAddrLowHalf);

            // 24-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_512 : begin
            // 9 = log2(512)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 9)) oAddrLowPart = truncateLSB(oAddrLowHalf);

            // 23-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_1024: begin
            // 10 = log2(1024)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 10)) oAddrLowPart = truncateLSB(oAddrLowHalf);

            // 22-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_2048: begin
            // 11 = log2(2048)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 11)) oAddrLowPart = truncateLSB(oAddrLowHalf);

            // 21-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
        IBV_MTU_4096: begin
            // 12 = log2(4096)
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) dAddrLowPart = truncateLSB(dAddrLowHalf);
            Bit#(TSub#(TSub#(ADDR_WIDTH, RDMA_MAX_LEN_WIDTH), 12)) oAddrLowPart = truncateLSB(oAddrLowHalf);

            // 20-bit comparison
            (dAddrLowPart == oAddrLowPart);
        end
    endcase;

    return addrMatch;
endfunction

typedef TDiv#(ADDR_WIDTH, 2) HALF_ADDR_WIDTH;

function Tuple2#(Bool, Bool) cmpHalfAddr(ADDR addrA, ADDR addrB);
    Bit#(HALF_ADDR_WIDTH) aAddrHighPart = truncateLSB(addrA);
    Bit#(HALF_ADDR_WIDTH) aAddrLowPart  = truncate(addrB);
    Bit#(HALF_ADDR_WIDTH) bAddrHighPart = truncateLSB(addrB);
    Bit#(HALF_ADDR_WIDTH) bAddrLowPart  = truncate(addrB);

    let addrHighPartMatch = aAddrHighPart == bAddrHighPart;
    let addrLowPartMatch  = aAddrLowPart  == bAddrLowPart;

    return tuple2(addrHighPartMatch, addrLowPartMatch);
endfunction

module mkBinaryTreeFork#(
    Bool clearAll, PipeOut#(anytype) pipeIn
)(Vector#(vSz, PipeOut#(anytype))) provisos(
    Bits#(anytype, tSz),
    // Add#(1, anysize, qSz),
    NumAlias#(TLog#(vSz), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(1, vSz))) // vSz must be power of 2
);
    Vector#(vSz, FIFOF#(anytype)) resultVec <- replicateM(mkFIFOF);

    for (Integer idx = 0; idx < valueOf(vSz); idx = idx + 1) begin
        rule resetAndClear if (clearAll);
            resultVec[idx].clear;
        endrule
    end

    if (valueOf(vSz) == valueOf(TWO)) begin
        rule discardInput if (clearAll);
            pipeIn.deq;
        endrule

        rule dupPipeIn if (!clearAll);
            let inputVal = pipeIn.first;
            pipeIn.deq;

            resultVec[0].enq(inputVal);
            resultVec[1].enq(inputVal);
        endrule
    end
    else begin
        Vector#(TDiv#(vSz, 2), PipeOut#(anytype)) halfSzPipeOutVec <-
            mkBinaryTreeFork(clearAll, pipeIn);

        for (Integer halfIdx = 0; halfIdx < valueOf(TDiv#(vSz, 2)); halfIdx = halfIdx + 1) begin
            rule dupPipeOut if (!clearAll);
                let pipeOutVal = halfSzPipeOutVec[halfIdx].first;
                halfSzPipeOutVec[halfIdx].deq;

                let leftIdx  = halfIdx * 2;
                let rightIdx = halfIdx * 2 + 1;
                resultVec[leftIdx].enq(pipeOutVal);
                resultVec[rightIdx].enq(pipeOutVal);
            endrule
        end
    end

    return map(toPipeOut, resultVec);
endmodule

module mkRecursiveSearch#(
    Bool clearAll,
    Vector#(vSz, PipeOut#(Maybe#(anytype))) inputVec
)(PipeOut#(Maybe#(anytype))) provisos(
    Bits#(anytype, tSz),
    // Add#(1, anysize, vSz),
    NumAlias#(TLog#(vSz), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(1, vSz))) // vSz must be power of 2
);
    if (valueOf(vSz) == 1) begin
        FIFOF#(Maybe#(anytype)) resultQ <- mkFIFOF;

        rule discardInput if (clearAll);
            inputVec[0].deq;
        endrule

        rule resetAndClear if (clearAll);
            resultQ.clear;
        endrule

        rule popOut if (!clearAll);
            let result = inputVec[0].first;
            inputVec[0].deq;

            resultQ.enq(result);
        endrule

        return toPipeOut(resultQ);
        // return inputVec[0];
    end
    else begin
        Vector#(TDiv#(vSz, 2), FIFOF#(Maybe#(anytype))) nextLayerVec <- replicateM(mkFIFOF);
        let nextLayerPipeOut = map(toPipeOut, nextLayerVec);
        let resultPipeOut <- mkRecursiveSearch(clearAll, nextLayerPipeOut);

        for (Integer idx = 0; idx < valueOf(vSz); idx = idx + valueOf(TWO)) begin
            rule pairCmp if (!clearAll);
                let outIdx = idx / valueOf(TWO);

                let leftPipeIn = inputVec[idx];
                let rightPipeIn = inputVec[idx + 1];

                let leftMaybe = leftPipeIn.first;
                leftPipeIn.deq;

                let rightMaybe = rightPipeIn.first;
                rightPipeIn.deq;

                let winMaybe = isValid(leftMaybe) ? leftMaybe : rightMaybe;
                nextLayerVec[outIdx].enq(winMaybe);
            endrule
        end

        for (Integer idx = 0; idx < valueOf(vSz); idx = idx + 1) begin
            rule discardInput if (clearAll);
                inputVec[idx].deq;
            endrule
        end

        for (Integer idx = 0; idx < valueOf(TDiv#(vSz, 2)); idx = idx + 1) begin
            rule resetAndClear if (clearAll);
                nextLayerVec[idx].clear;
            endrule
        end
        return resultPipeOut;
    end
endmodule

module mkCacheFIFO#(
    function searchType firstStageFunc(anytype item4Search, anytype itemInQ),
    function cmpResultType secondStageFunc(searchType searchData),
    function Maybe#(anytype) thirdStageFunc(cmpResultType searchResult)
)(CacheFIFO#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    Bits#(searchType, searchTypeSz),
    Bits#(cmpResultType, cmpResultTypeSz),
    NumAlias#(TLog#(qSz), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(1, qSz))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Vector#(qSz, Reg#(Bool))     tagVec <- replicateM(mkReg(False));

    FIFOF#(anytype)    insertQ <- mkFIFOF;
    FIFOF#(anytype) searchReqQ <- mkFIFOF;
    // FIFOF#(Maybe#(anytype)) searchRespQ <- mkFIFOF;

    // Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);

    Reg#(Bit#(cntSz)) enqPtrReg <- mkReg(0);

    Vector#(qSz, PipeOut#(anytype)) searchReqPipeOutVec <- mkBinaryTreeFork(
        clearReg[1], toPipeOut(searchReqQ)
    );
    // Vector#(qSz, FIFOF#(anytype))                    searchReqVec <- replicateM(mkFIFOF);
    Vector#(qSz, FIFOF#(Tuple2#(Bool, searchType))) searchDataVec <- replicateM(mkFIFOF);
    Vector#(qSz, FIFOF#(Maybe#(cmpResultType)))      cmpResultVec <- replicateM(mkFIFOF);
    Vector#(qSz, FIFOF#(Maybe#(anytype)))         searchResultVec <- replicateM(mkFIFOF);

    let firstSearchStageZipVec = zip3(readVReg(tagVec), readVReg(dataVec), searchDataVec);
    let searchResultPipeOutVec = map(toPipeOut, searchResultVec);
    let searchResultPipeOut   <- mkRecursiveSearch(clearReg[1], searchResultPipeOutVec);

    function Action clearSearchDataQ(FIFOF#(Tuple2#(Bool, searchType)) searchDataQ);
        action
            searchDataQ.clear;
        endaction
    endfunction

    function Action clearCmpResultQ(FIFOF#(Maybe#(cmpResultType)) cmpResultQ);
        action
            cmpResultQ.clear;
        endaction
    endfunction

    function Action clearSearchResultQ(FIFOF#(Maybe#(anytype)) searchResultQ);
        action
            searchResultQ.clear;
        endaction
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule clearAll if (clearReg[1]);
        writeVReg(tagVec, replicate(False));
        insertQ.clear;
        searchReqQ.clear;
        enqPtrReg <= 0;

        mapM_(clearSearchDataQ, searchDataVec);
        mapM_(clearCmpResultQ, cmpResultVec);
        mapM_(clearSearchResultQ, searchResultVec);

        clearReg[1] <= False;
        // pushReg[1]  <= tagged Invalid;
    endrule

    // Insert requests take two cycles to finish insertion
    rule insert if (!clearReg[1]);
        let insertVal = insertQ.first;
        insertQ.deq;

        dataVec[enqPtrReg] <= insertVal;
        tagVec[enqPtrReg]  <= True;

        enqPtrReg <= enqPtrReg + 1;
    endrule
/*
    function Action firstMapFunc(
        function searchType mapFunc(anytype item4Cmp),
        Tuple3#(Bool, anytype, FIFOF#(Tuple2#(Bool, searchType))) zip3Item
    );
        action
            let { tag, itemInQ, searchDataQ } = zip3Item;
            let searchData = mapFunc(itemInQ);
            searchDataQ.enq(tuple2(tag, searchData));
        endaction
    endfunction

    rule firstSearchStage if (!clearReg[1]);
        let item4Search = searchReqQ.first;
        searchReqQ.deq;

        mapM_(firstMapFunc(firstStageFunc(item4Search)), firstSearchStageZipVec);
    endrule

    function Action duplicateSearchReq(anytype item4Cmp, FIFOF#(anytype) dupSearchReqQ);
        action
            dupSearchReqQ.enq(item4Cmp);
        endaction
    endfunction

    rule duplicateSearchReqStage if (!clearReg[1]);
        let item4Search = searchReqQ.first;
        searchReqQ.deq;

        mapM_(duplicateSearchReq(item4Search), searchReqVec);
    endrule
*/
    for (Integer idx = 0; idx < valueOf(qSz); idx = idx + 1) begin
        rule firstSearchStage if (!clearReg[1]);
            let item4Search = searchReqPipeOutVec[idx].first;
            searchReqPipeOutVec[idx].deq;

            let { tag, itemInQ, searchDataQ } = firstSearchStageZipVec[idx];
            let searchData = firstStageFunc(item4Search, itemInQ);
            searchDataVec[idx].enq(tuple2(tag, searchData));
        endrule

        rule secondSearchStage if (!clearReg[1]);
            let searchDataQ = searchDataVec[idx];
            let { tag, searchData } = searchDataQ.first;
            searchDataQ.deq;

            let cmpResult = secondStageFunc(searchData);
            let cmpResultQ = cmpResultVec[idx];
            let outResult = tag ? (tagged Valid cmpResult) : (tagged Invalid);
            cmpResultQ.enq(outResult);
        endrule

        rule thirdSearchStage if (!clearReg[1]);
            let cmpResultQ = cmpResultVec[idx];
            let searchResultQ = searchResultVec[idx];

            let maybeCmpResult = cmpResultQ.first;
            cmpResultQ.deq;

            let maybeSearchResult = tagged Invalid;
            if (maybeCmpResult matches tagged Valid .cmpResult) begin
                maybeSearchResult = thirdStageFunc(cmpResult);
            end
            searchResultQ.enq(maybeSearchResult);
        endrule
    end

    interface cacheIfc = interface CacheIfc#(anytype);
        method Action push(anytype pushVal);
            insertQ.enq(pushVal);
            // pushReg[0] <= tagged Valid pushVal;
        endmethod

        method Action clear();
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc#(anytype);
        method Action searchReq(anytype item2Search);
            searchReqQ.enq(item2Search);
        endmethod

        method ActionValue#(Maybe#(anytype)) searchResp();
            let maybeSearchResult = searchResultPipeOut.first;
            searchResultPipeOut.deq;
            return maybeSearchResult;
        endmethod
    endinterface;
endmodule

typedef enum {
    DUP_READ_REQ_START_FROM_FIRST,
    DUP_READ_REQ_START_FROM_MIDDLE
} DupReadReqStartState deriving(Bits, Eq, FShow);

typedef struct {
    PSN  startPSN;
    PSN  endPSN;
    RETH reth;
} ReadCacheItem deriving(Bits);

typedef struct {
    PSN          atomicPSN;
    RdmaOpCode   atomicOpCode;
    AtomicEth    atomicEth;
    AtomicAckEth atomicAckEth;
} AtomicCacheItem deriving(Bits);

interface DupReadAtomicCache;
    method Action insertRead(ReadCacheItem dupReadCacheItem);
    // interface Server#(ReadCacheItem, Maybe#(Tuple3#(
    //     ReadCacheItem, ADDR, DupReadReqStartState
    // ))) dupReadQuerySrv;
    method Action searchReadReq(ReadCacheItem readCacheItem2Search);
    method ActionValue#(Maybe#(Tuple3#(
        ReadCacheItem, ADDR, DupReadReqStartState
    ))) searchReadResp();

    method Action insertAtomic(AtomicCacheItem atomicCache);
    // interface Server#(AtomicCacheItem, Maybe#(AtomicCacheItem)) dupAtomicQuerySrv;
    method Action searchAtomicReq(AtomicCacheItem atomicCacheItem2Search);
    method ActionValue#(Maybe#(AtomicCacheItem)) searchAtomicResp();

    method Action clear();
endinterface

typedef struct {
    Bool addrHighHalfMatch;
    Bool addrLowHalfMatch;
    Bool keyMatch;
    Bool psnStartExactMatch;
    Bool psnStartRangeMatch;
    Bool psnEndExactMatch;
    Bool psnEndRangeMatch;
    Bool readLenMatch;
} DupReadCmpParts deriving(Bits);

typedef struct {
    Bool addrHighPartMatch;
    Bool addrLowPartMatch;
    // Bool payloadMatch;
    Bool compMatch;
    Bool keyMatch;
    Bool opCodeMatch;
    Bool psnMatch;
    Bool swapMatch;
} DupAtomicCmpParts deriving(Bits);

// No need to consider concurrent search and insert,
// since ReqHandleRQ garrentees insert before search.
module mkDupReadAtomicCache#(PMTU pmtu)(DupReadAtomicCache);
    function Tuple6#(
        PMTU, Bool, Bool, Bool, ReadCacheItem, ReadCacheItem
    ) buildDupReadSearchData(
        PMTU pmtu, ReadCacheItem dupReadCacheItem, ReadCacheItem origReadCacheItem
    );
        let dupReadReth  = dupReadCacheItem.reth;
        let origReadReth = origReadCacheItem.reth;
        let dupStartPSN  = dupReadCacheItem.startPSN;
        let dupEndPSN    = dupReadCacheItem.endPSN;
        let origStartPSN = origReadCacheItem.startPSN;
        let origEndPSN   = origReadCacheItem.endPSN;
        let dupRKey      = dupReadReth.rkey;
        let origRKey     = origReadReth.rkey;

        let psnStartExactMatch = dupStartPSN == origStartPSN;
        let psnEndExactMatch   = dupEndPSN   == origEndPSN;
        let keyMatch           = dupRKey     == origRKey;

        return tuple6(
            pmtu, psnStartExactMatch, psnEndExactMatch,
            keyMatch, dupReadCacheItem, origReadCacheItem
        );
    endfunction

    function Tuple4#(
        DupReadCmpParts, ReadRespLastPktAddrPart, ReadRespLastPktAddrPart, ReadCacheItem
    ) compareReadCacheItem(
        Tuple6#(PMTU, Bool, Bool, Bool, ReadCacheItem, ReadCacheItem) searchData
    );
        let {
            pmtu, psnStartExactMatch, psnEndExactMatch,
            keyMatch, dupReadCacheItem, origReadCacheItem
        } = searchData;

        let dupReadReth  = dupReadCacheItem.reth;
        let origReadReth = origReadCacheItem.reth;
        let dupStartPSN  = dupReadCacheItem.startPSN;
        let dupEndPSN    = dupReadCacheItem.endPSN;
        let origStartPSN = origReadCacheItem.startPSN;
        let origEndPSN   = origReadCacheItem.endPSN;

        // let keyMatch           = dupReadReth.rkey == origReadReth.rkey;
        let psnStartRangeMatch = psnInRangeExclusive(dupStartPSN, origStartPSN, origEndPSN);
        let psnEndRangeMatch   = psnInRangeExclusive(dupEndPSN, origStartPSN, origEndPSN);

        let {
            addrHighHalfMatch, addrLowHalfMatch, readLenMatch,
            dupReadLastPktAddrPart, origReadLastPktAddrPart
        } = computeReadEndAddrAndCompare(pmtu, dupReadReth, origReadReth);

        let dupReadCmpParts = DupReadCmpParts {
            addrHighHalfMatch : addrHighHalfMatch,
            addrLowHalfMatch  : addrLowHalfMatch,
            keyMatch          : keyMatch,
            psnStartExactMatch: psnStartExactMatch,
            psnStartRangeMatch: psnStartRangeMatch,
            psnEndExactMatch  : psnEndExactMatch,
            psnEndRangeMatch  : psnEndRangeMatch,
            readLenMatch      : readLenMatch
        };
        return tuple4(
            dupReadCmpParts, dupReadLastPktAddrPart, origReadLastPktAddrPart, origReadCacheItem
        );
    endfunction

    function Maybe#(ReadCacheItem) checkReadCacheItemCmpResult(
        Tuple4#(
            DupReadCmpParts, ReadRespLastPktAddrPart, ReadRespLastPktAddrPart, ReadCacheItem
        ) cmpResult
    );
        let {
            dupReadCmpParts, dupReadLastPktAddrPart, origReadLastPktAddrPart, origReadCacheItem
        } = cmpResult;

        let addrHighHalfMatch  = dupReadCmpParts.addrHighHalfMatch;
        let addrLowHalfMatch   = dupReadCmpParts.addrLowHalfMatch;
        let keyMatch           = dupReadCmpParts.keyMatch;
        let psnStartExactMatch = dupReadCmpParts.psnStartExactMatch;
        let psnStartRangeMatch = dupReadCmpParts.psnStartRangeMatch;
        let psnEndExactMatch   = dupReadCmpParts.psnEndExactMatch;
        let psnEndRangeMatch   = dupReadCmpParts.psnEndRangeMatch;
        let readLenMatch       = dupReadCmpParts.readLenMatch;

        let addrLenMatch =
            addrHighHalfMatch && addrLowHalfMatch && readLenMatch &&
            dupReadLastPktAddrPart == origReadLastPktAddrPart;

        let psnMatch = (psnStartExactMatch || psnStartRangeMatch) &&
            (psnEndExactMatch || psnEndRangeMatch);

        return (addrLenMatch && keyMatch && psnMatch) ?
            (tagged Valid origReadCacheItem) : (tagged Invalid);
    endfunction

    function Tuple5#(Bool, Bool, Bool, AtomicCacheItem, AtomicCacheItem) buildAtomicSearchData(
        AtomicCacheItem dupAtomicCacheItem, AtomicCacheItem origAtomicCacheItem
    );
        let dupAtomicOpCode  = dupAtomicCacheItem.atomicOpCode;
        let origAtomicOpCode = origAtomicCacheItem.atomicOpCode;
        let dupAtomicEth     = dupAtomicCacheItem.atomicEth;
        let origAtomicEth    = origAtomicCacheItem.atomicEth;


        let keyMatch    = dupAtomicEth.rkey == origAtomicEth.rkey;
        let opCodeMatch = dupAtomicOpCode == origAtomicOpCode;
        let psnMatch    = dupAtomicCacheItem.atomicPSN == origAtomicCacheItem.atomicPSN;

        return tuple5(keyMatch, opCodeMatch, psnMatch, dupAtomicCacheItem, origAtomicCacheItem);
    endfunction

    function Tuple2#(DupAtomicCmpParts, AtomicCacheItem) compareAtomicCacheItem(
        Tuple5#(Bool, Bool, Bool, AtomicCacheItem, AtomicCacheItem) searchData
    );
        let {
            keyMatch, opCodeMatch, psnMatch, dupAtomicCacheItem, origAtomicCacheItem
        } = searchData;

        let dupAtomicEth  = dupAtomicCacheItem.atomicEth;
        let origAtomicEth = origAtomicCacheItem.atomicEth;

        let { addrHighPartMatch, addrLowPartMatch } = cmpHalfAddr(
            dupAtomicEth.va, origAtomicEth.va
        );

        let swapMatch = dupAtomicEth.swap == origAtomicEth.swap;
        let compMatch = dupAtomicEth.comp == origAtomicEth.comp;
        // let payloadMatch = case (dupAtomicOpCode)
        //     COMPARE_SWAP: (dupAtomicEth.comp == origAtomicEth.comp && swapMatch);
        //     FETCH_ADD   : swapMatch;
        //     default     : False;
        // endcase;

        let dupAtomicCmpParts = DupAtomicCmpParts {
            addrHighPartMatch: addrHighPartMatch,
            addrLowPartMatch : addrLowPartMatch,
            compMatch        : compMatch,
            keyMatch         : keyMatch,
            opCodeMatch      : opCodeMatch,
            // payloadMatch     : payloadMatch,
            psnMatch         : psnMatch,
            swapMatch        : swapMatch
        };
        return tuple2(dupAtomicCmpParts, origAtomicCacheItem);
    endfunction

    function Maybe#(AtomicCacheItem) checkAtomicCacheItemCmpResult(
        Tuple2#(DupAtomicCmpParts, AtomicCacheItem) cmpResult
    );
        let { dupAtomicCmpParts, origAtomicCacheItem } = cmpResult;
        let origAtomicOpCode = origAtomicCacheItem.atomicOpCode;

        let addrHighPartMatch = dupAtomicCmpParts.addrHighPartMatch;
        let addrLowPartMatch  = dupAtomicCmpParts.addrLowPartMatch;
        let keyMatch          = dupAtomicCmpParts.keyMatch;
        let opCodeMatch       = dupAtomicCmpParts.opCodeMatch;
        let swapMatch         = dupAtomicCmpParts.swapMatch;
        let compMatch         = dupAtomicCmpParts.compMatch;
        // let payloadMatch      = dupAtomicCmpParts.payloadMatch;
        let psnMatch          = dupAtomicCmpParts.psnMatch;

        let payloadMatch = origAtomicOpCode == COMPARE_SWAP ? (swapMatch && compMatch) : swapMatch;
        let allMatch = addrHighPartMatch && addrLowPartMatch && keyMatch &&
            payloadMatch && opCodeMatch && psnMatch;
        return allMatch ?
            (tagged Valid origAtomicCacheItem) : (tagged Invalid);
    endfunction

    CacheFIFO#(MAX_QP_RD_ATOM, ReadCacheItem) readCacheQ <- mkCacheFIFO(
        buildDupReadSearchData(pmtu), compareReadCacheItem, checkReadCacheItemCmpResult
    );
    CacheFIFO#(MAX_QP_RD_ATOM, AtomicCacheItem) atomicCacheQ <- mkCacheFIFO(
        buildAtomicSearchData, compareAtomicCacheItem, checkAtomicCacheItemCmpResult
    );
    FIFOF#(ReadCacheItem) dupReadReqQ <- mkFIFOF;
    FIFOF#(Maybe#(Tuple3#(
        ReadCacheItem, ADDR, DupReadReqStartState
    ))) dupReadRespQ <- mkFIFOF;

    rule postProcessDupReadResp;
        let dupReadCacheItem = dupReadReqQ.first;
        dupReadReqQ.deq;
        let dupReadReth = dupReadCacheItem.reth;

        let readResp = tagged Invalid;
        let searchResult <- readCacheQ.searchIfc.searchResp;
        if (searchResult matches tagged Valid .origReadCacheItem) begin
            let origReadReth = origReadCacheItem.reth;
            let dupReadStartAddrMatch = compareDupReadAddr(
                pmtu, dupReadReth, origReadReth
            );
            let verifiedDupReadAddr = getVerifiedDupReadAddr(dupReadReth, origReadReth);
            if (dupReadStartAddrMatch) begin
                readResp = tagged Valid tuple3(
                    origReadCacheItem, verifiedDupReadAddr, DUP_READ_REQ_START_FROM_FIRST
                );
            end
            else begin
                readResp = tagged Valid tuple3(
                    origReadCacheItem, verifiedDupReadAddr, DUP_READ_REQ_START_FROM_MIDDLE
                );
            end

            // $display(
            //     "time=%0t: dupReadReth.rkey=%h, origReadReth.rkey=%h",
            //     $time, dupReadReth.rkey, origReadReth.rkey,
            //     ", dupReadReth.va=%h, origReadReth.va=%h",
            //     dupReadReth.va, origReadReth.va,
            //     ", dupReadReth.dlen=%h, origReadReth.dlen=%h",
            //     dupReadReth.dlen, origReadReth.dlen,
            //     ", dupReadAddrMatch=", fshow(dupReadAddrMatch)
            // );
        end

        dupReadRespQ.enq(readResp);
    endrule

    method Action insertRead(ReadCacheItem readCacheItem);
        readCacheQ.cacheIfc.push(readCacheItem);
    endmethod

    method Action searchReadReq(ReadCacheItem readCacheItem2Search);
        readCacheQ.searchIfc.searchReq(readCacheItem2Search);
        dupReadReqQ.enq(readCacheItem2Search);
    endmethod

    method ActionValue#(Maybe#(Tuple3#(
        ReadCacheItem, ADDR, DupReadReqStartState
    ))) searchReadResp();
        let readResp = dupReadRespQ.first;
        dupReadRespQ.deq;
        return readResp;
    endmethod

    method Action insertAtomic(AtomicCacheItem atomicCache);
        atomicCacheQ.cacheIfc.push(atomicCache);
    endmethod

    method Action searchAtomicReq(AtomicCacheItem atomicCacheItem2Search);
        atomicCacheQ.searchIfc.searchReq(atomicCacheItem2Search);
    endmethod

    method ActionValue#(Maybe#(AtomicCacheItem)) searchAtomicResp();
        let searchResult <- atomicCacheQ.searchIfc.searchResp;
        return searchResult;
    endmethod

    method Action clear();
        readCacheQ.cacheIfc.clear;
        atomicCacheQ.cacheIfc.clear;
    endmethod
endmodule
