import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

typedef Bit#(64) ItemType;

(* synthesize *)
module mkTestCacheFIFO(Empty);
    function Tuple2#(ItemType, ItemType) convertFunc(ItemType item4Search, ItemType itemInQ);
        return tuple2(item4Search, itemInQ);
    endfunction

    function Tuple2#(Bool, ItemType) compareFunc(Tuple2#(ItemType, ItemType) searchData);
        let { item4Search, itemInQ } = searchData;
        return tuple2(item4Search == itemInQ, itemInQ);
    endfunction

    function Maybe#(ItemType) checkCompareResult(Tuple2#(Bool, ItemType) searchResult);
        let { found, result } = searchResult;
        return found ? (tagged Valid result) : (tagged Invalid);
    endfunction

    CacheFIFO#(MAX_QP_RD_ATOM, ItemType) cacheQ <- mkCacheFIFO(
        convertFunc, compareFunc, checkCompareResult
    );

    PipeOut#(ItemType) qElemPipeOut <- mkGenericRandomPipeOut;
    Vector#(3, PipeOut#(ItemType)) qElemPipeOutVec <-
        mkForkVector(qElemPipeOut);
    let qElemPipeOut4Q = qElemPipeOutVec[0];
    let qElemPipeOut4SearchReq <- mkBufferN(2, qElemPipeOutVec[1]);
    let qElemPipeOut4SearchResp <- mkBufferN(2, qElemPipeOutVec[2]);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule pushCacheQ;
        let curEnqData = qElemPipeOut4Q.first;
        qElemPipeOut4Q.deq;

        cacheQ.cacheIfc.push(curEnqData);
        // $display(
        //     "time=%0t: curEnqData=%h when in fill mode",
        //     $time, curEnqData
        // );
    endrule

    rule searchReq;
        let searchData = qElemPipeOut4SearchReq.first;
        qElemPipeOut4SearchReq.deq;

        cacheQ.searchIfc.searchReq(searchData);
    endrule

    rule compareSearchResp;
        countDown.decr;

        let searchResult <- cacheQ.searchIfc.searchResp;

        let refSearchData = qElemPipeOut4SearchResp.first;
        qElemPipeOut4SearchResp.deq;

        immAssert(
            isValid(searchResult),
            "searchResult assertion @ mkTestCacheFIFO",
            $format(
                "searchResult=", fshow(searchResult),
                " should be valid"
            )
        );

        let searchData = unwrapMaybe(searchResult);
        immAssert(
            searchData == refSearchData,
            "searchData assertion @ mkTestCacheFIFO",
            $format(
                "searchData=%h should == refSearchData=%h",
                searchData, refSearchData
            )
        );
        // $display(
        //     "time=%0t: searchData=%h should == refSearchData=%h",
        //     $time, searchData, refSearchData
        // );
    endrule
endmodule

(* synthesize *)
module mkTestDupReadAtomicCache(Empty);
    function Bool compareDupReadAddrAndLen(PMTU pmtu, RETH dupReadReth, RETH origReadReth);
        let {
            addrHighHalfMatch, addrLowHalfMatch, readLenMatch,
            dupReadLastPktAddrPart, origReadLastPktAddrPart
        } = computeReadEndAddrAndCompare(pmtu, dupReadReth, origReadReth);

        let addrLenMatch =
            addrHighHalfMatch && addrLowHalfMatch && readLenMatch &&
            dupReadLastPktAddrPart == origReadLastPktAddrPart;
        return addrLenMatch;
    endfunction

    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_1024;

    PipeOut#(PSN)            psn4ReadPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(PSN)          psn4AtomicPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR)          addr4ReadPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR)        addr4AtomicPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Length)              lenPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY)          rKey4ReadPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY)        rKey4AtomicPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long)               compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long)               swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long)               origPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RdmaOpCode) atomicOpCodePipeOut <- mkRandomAtomicReqRdmaOpCode;

    FIFOF#(Tuple3#(ReadCacheItem, ReadCacheItem, DupReadReqStartState))  readSearchReqQ <- mkFIFOF;
    FIFOF#(Tuple3#(ReadCacheItem, ReadCacheItem, DupReadReqStartState)) readSearchRespQ <- mkFIFOF;
    FIFOF#(AtomicCacheItem)  atomicSearchReqQ <- mkFIFOF;
    FIFOF#(AtomicCacheItem) atomicSearchRespQ <- mkFIFOF;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);

    let dut <- mkDupReadAtomicCache(cntrl.cntrlStatus.getPMTU);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule insertReadReth;
        let psn = psn4ReadPipeOut.first;
        psn4ReadPipeOut.deq;

        let addr = addr4ReadPipeOut.first;
        addr4ReadPipeOut.deq;

        let len = lenPipeOut.first;
        lenPipeOut.deq;

        let rkey = rKey4ReadPipeOut.first;
        rKey4ReadPipeOut.deq;

        let { isOnlyRespPkt, respPktNum, nextPktSeqNum, endPktSeqNum } =
            calcPktNumNextAndEndPSN(psn, len, pmtu);

        let readCacheItem = ReadCacheItem {
            startPSN: psn,
            endPSN  : endPktSeqNum,
            reth    : RETH {
                va  : addr,
                dlen: len,
                rkey: rkey
            }
        };
        dut.insertRead(readCacheItem);

        let twoAsPSN = 2;
        if (lenGtEqPsnMultiplyPMTU(len, twoAsPSN, pmtu)) begin
            let dupStartPSN = psn + twoAsPSN;
            let dupAddr = addrAddPsnMultiplyPMTU(addr, twoAsPSN, pmtu);
            let dupLen = lenSubtractPsnMultiplyPMTU(len, twoAsPSN, pmtu);

            let dupReadCacheItem = ReadCacheItem {
                startPSN: dupStartPSN,
                endPSN  : endPktSeqNum,
                reth    : RETH {
                    va  : dupAddr,
                    dlen: dupLen,
                    rkey: rkey
                }
            };
            readSearchReqQ.enq(tuple3(
                readCacheItem, dupReadCacheItem, DUP_READ_REQ_START_FROM_MIDDLE
            ));

            // let errReadReth = RETH {
            //     va  : addr + 1,
            //     dlen: len - 1,
            //     rkey: rkey
            // };
            let addrLenMatch = compareDupReadAddrAndLen(
                pmtu, readCacheItem.reth, dupReadCacheItem.reth
            );
            // $display(
            //     "time=%0t: addrLenMatch=", $time, fshow(addrLenMatch),
            //     ", dupReadCacheItem.reth.va=%h, origReadCacheItem.reth.va=%h",
            //     dupReadCacheItem.reth.va, readCacheItem.reth.va,
            //     ", dupReadCacheItem.reth.dlen=%h, origReadCacheItem.reth.dlen=%h",
            //     dupReadCacheItem.reth.dlen, readCacheItem.reth.dlen
            // );
        end
        else begin
            let dupReadCacheItem = readCacheItem;
            readSearchReqQ.enq(tuple3(
                readCacheItem, dupReadCacheItem, DUP_READ_REQ_START_FROM_FIRST
            ));
        end
    endrule

    rule searchReadReq;
        let {
            origReadCacheItem, dupReadCacheItem, dupReadReqStartState
        } = readSearchReqQ.first;
        readSearchReqQ.deq;

        dut.searchReadReq(dupReadCacheItem);
        readSearchRespQ.enq(tuple3(origReadCacheItem, dupReadCacheItem, dupReadReqStartState));
    endrule

    rule searchReadResp;
        let {
            origReadCacheItem, dupReadCacheItem, exptectedDupReadReqStartState
        }= readSearchRespQ.first;
        readSearchRespQ.deq;

        let maybeSearchReadResp <- dut.searchReadResp;
        immAssert(
            isValid(maybeSearchReadResp),
            "maybeSearchReadResp assertion @ mkTestDupReadAtomicCache",
            $format(
                "isValid(maybeSearchReadResp)=",
                fshow(isValid(maybeSearchReadResp)),
                " should be valid"
            )
        );

        let {
            searchReadCacheItem, verifiedDupReadAddr, dupReadReqStartState
        } = unwrapMaybe(maybeSearchReadResp);
        immAssert(
            searchReadCacheItem.startPSN  == origReadCacheItem.startPSN  &&
            searchReadCacheItem.endPSN    == origReadCacheItem.endPSN    &&
            searchReadCacheItem.reth.rkey == origReadCacheItem.reth.rkey &&
            searchReadCacheItem.reth.dlen == origReadCacheItem.reth.dlen &&
            searchReadCacheItem.reth.va   == origReadCacheItem.reth.va   &&
            dupReadCacheItem.reth.va      == verifiedDupReadAddr         &&
            dupReadReqStartState          == exptectedDupReadReqStartState,
            "read cache search response assertion @ mkTestDupReadAtomicCache",
            $format(
                "dupReadReqStartState=", fshow(dupReadReqStartState),
                " should == exptectedDupReadReqStartState=",
                fshow(exptectedDupReadReqStartState),
                " and dupReadCacheItem.reth.va=%h should == verifiedDupReadAddr=%h",
                dupReadCacheItem.reth.va, verifiedDupReadAddr
            )
        );
    endrule

    rule insertAtomicCache;
        let atomicPSN = psn4AtomicPipeOut.first;
        psn4AtomicPipeOut.deq;

        let atomicOpCode = atomicOpCodePipeOut.first;
        atomicOpCodePipeOut.deq;

        let addr = addr4AtomicPipeOut.first;
        addr4AtomicPipeOut.deq;

        let rkey = rKey4AtomicPipeOut.first;
        rKey4AtomicPipeOut.deq;

        let comp = compPipeOut.first;
        compPipeOut.deq;

        let swap = swapPipeOut.first;
        swapPipeOut.deq;

        let orig = origPipeOut.first;
        origPipeOut.deq;

        let atomicEth = AtomicEth {
            va  : addr,
            rkey: rkey,
            comp: comp,
            swap: swap
        };

        let atomicAckEth = AtomicAckEth { orig: orig };

        let atomicCacheItem = AtomicCacheItem {
            atomicPSN   : atomicPSN,
            atomicOpCode: atomicOpCode,
            atomicEth   : atomicEth,
            atomicAckEth: atomicAckEth
        };

        dut.insertAtomic(atomicCacheItem);
        atomicSearchReqQ.enq(atomicCacheItem);
    endrule

    rule searchAtomicReq;
        let atomicCacheItem = atomicSearchReqQ.first;
        atomicSearchReqQ.deq;

        dut.searchAtomicReq(atomicCacheItem);
        atomicSearchRespQ.enq(atomicCacheItem);
    endrule

    rule searchAtomicResp;
        let exptectedAtomicCache = atomicSearchRespQ.first;
        atomicSearchRespQ.deq;

        let maybeSearchAtomicResp <- dut.searchAtomicResp;
        immAssert(
            isValid(maybeSearchAtomicResp),
            "maybeSearchAtomicResp assertion @ mkTestDupReadAtomicCache",
            $format(
                "isValid(maybeSearchAtomicResp)=", fshow(isValid(maybeSearchAtomicResp)),
                " should be valid"
            )
        );

        let searchAtomicResp = unwrapMaybe(maybeSearchAtomicResp);
        let searchAtomicRespPSN = searchAtomicResp.atomicPSN;
        let exptectedAtomicRespPSN = exptectedAtomicCache.atomicPSN;
        let searchAtomicRespOpCode = searchAtomicResp.atomicOpCode;
        let exptectedAtomicRespOpCode = exptectedAtomicCache.atomicOpCode;
        let searchAtomicRespAddr = searchAtomicResp.atomicEth.va;
        let exptectedAtomicRespAddr = exptectedAtomicCache.atomicEth.va;
        let searchAtomicRespRKey = searchAtomicResp.atomicEth.rkey;
        let exptectedAtomicRespRKey = exptectedAtomicCache.atomicEth.rkey;
        let searchAtomicRespComp = searchAtomicResp.atomicEth.comp;
        let exptectedAtomicRespComp = exptectedAtomicCache.atomicEth.comp;
        let searchAtomicRespSwap = searchAtomicResp.atomicEth.swap;
        let exptectedAtomicRespSwap = exptectedAtomicCache.atomicEth.swap;
        let searchAtomicRespOrig = searchAtomicResp.atomicAckEth.orig;
        let exptectedAtomicRespOrig = exptectedAtomicCache.atomicAckEth.orig;
        immAssert(
            searchAtomicRespPSN    == exptectedAtomicRespPSN  &&
            searchAtomicRespOrig   == exptectedAtomicRespOrig &&
            searchAtomicRespAddr   == exptectedAtomicRespAddr &&
            searchAtomicRespRKey   == exptectedAtomicRespRKey &&
            searchAtomicRespComp   == exptectedAtomicRespComp &&
            searchAtomicRespSwap   == exptectedAtomicRespSwap &&
            searchAtomicRespOpCode == exptectedAtomicRespOpCode,
            "searchAtomicRespOrig assertion @ mkTestDupReadAtomicCache",
            $format(
                "searchAtomicRespOrig=", fshow(searchAtomicRespOrig),
                " should == exptectedAtomicRespOrig=",
                fshow(exptectedAtomicRespOrig)
            )
        );

        // $display(
        //     "time=%0t:", $time,
        //     " searchAtomicRespOrig=", fshow(searchAtomicRespOrig),
        //     " should == exptectedAtomicRespOrig=",
        //     fshow(exptectedAtomicRespOrig)
        // );
        countDown.decr;
    endrule
endmodule
