import Cntrs :: *;
import FIFOF :: *;
import PAClib :: *;
import PrimUtils :: *;
import Vector :: *;

// interface ScanOutIfc#(type anytype);
//     method anytype current();
//     method Action next();
//     // method Bool isEmpty();
// endinterface

interface ScanCntrl#(type anytype);
    method anytype getHead();
    method Action modifyHead(anytype head);
    method Action preScanStart();
    method Action scanStart();
    method Action scanStop();
    method Action preScanRestart();
    method Action clear();
    method Bool hasScanOut();
    method Bool isScanDone();
    // method Bool isScanMode();
endinterface

interface ScanFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifof;
    interface ScanCntrl#(anytype) scanCntrl;
    interface PipeOut#(anytype) scanPipeOut;
    method UInt#(TLog#(TAdd#(qSz, 1))) size();
endinterface

typedef enum {
    SCAN_Q_FIFOF_MODE,
    SCAN_Q_PRE_SCAN_MODE,
    SCAN_Q_SCAN_MODE
} ScanState deriving(Bits, Eq, FShow);

// ScanFIFOF is frozon when in SCAN_Q_PRE_SCAN_MODE,
// and no enqueue when in SCAN_Q_SCAN_MODE.
module mkScanFIFOF(ScanFIFOF#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(qSz), ptrSz),
    NumAlias#(TAdd#(ptrSz, 1), cntSz),
    Add#(1, anysize, TLog#(qSz)), // qSz must at least be 2
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Reg#(Bit#(ptrSz))         enqPtrReg <- mkReg(0);
    Reg#(Bit#(ptrSz))         deqPtrReg <- mkReg(0);
    Reg#(Bit#(ptrSz))        scanPtrReg <- mkRegU;
    Reg#(ScanState)        scanStateReg <- mkReg(SCAN_Q_FIFOF_MODE);
    Reg#(Bool)                  fullReg <- mkReg(False);
    Reg#(Bool)                 emptyReg <- mkReg(True);
    Reg#(Maybe#(anytype))       headReg <- mkRegU;
    Reg#(Bool)        scanAlmostDoneReg <- mkRegU;
    Count#(Bit#(cntSz))         itemCnt <- mkCount(0);
    Count#(Bit#(cntSz))         scanCnt <- mkCount(0);

    // Reg#(Maybe#(anytype)) headReg[2] <- mkCRegU(2);
    Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             popReg[2] <- mkCReg(2, False);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);
    Reg#(Bool)    preScanStartReg[2] <- mkCReg(2, False);
    Reg#(Bool)       scanStartReg[2] <- mkCReg(2, False);
    Reg#(Bool)        scanStopReg[2] <- mkCReg(2, False);
    Reg#(Bool)  preScanRestartReg[2] <- mkCReg(2, False);
    Reg#(Bool)        scanDoneReg[2] <- mkCReg(2, False);

    FIFOF#(anytype) scanOutQ <- mkFIFOF;

    let inFifoMode    = scanStateReg == SCAN_Q_FIFOF_MODE;
    let inScanMode    = scanStateReg == SCAN_Q_SCAN_MODE;
    let inPreScanMode = scanStateReg == SCAN_Q_PRE_SCAN_MODE;

    function Bit#(ptrSz) getNextDeqPtr();
        return popReg[1] ? (deqPtrReg + 1) : deqPtrReg;
    endfunction

    function Bool isEmpty() = emptyReg;
    function Bool  isFull() = fullReg;

    function Bool  isAlmostFull() = isAllOnesR(removeMSB(itemCnt));
    function Bool isAlmostEmpty() = isOne(itemCnt);

    (* no_implicit_conditions, fire_when_enabled *)
    rule clearAll if (clearReg[1]);
        enqPtrReg     <= 0;
        deqPtrReg     <= 0;
        itemCnt       <= 0;
        // scanCnt       <= 0; // No need to init scanCnt
        fullReg       <= False;
        emptyReg      <= True;
        scanStateReg  <= SCAN_Q_FIFOF_MODE;

        pushReg[1]           <= tagged Invalid;
        popReg[1]            <= False;
        preScanStartReg[1]   <= False;
        scanStartReg[1]      <= False;
        scanStopReg[1]       <= False;
        preScanRestartReg[1] <= False;
        scanDoneReg[1]       <= False;

        clearReg[1]          <= False;
        // $display("time=%0t: clear ScanFIFOF", $time);
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize if (!clearReg[1]);
        let hasPush    = isValid(pushReg[1]);
        let hasPop     = popReg[1];
        let nextEnqPtr = hasPush ? (enqPtrReg + 1) : enqPtrReg;
        let nextDeqPtr = getNextDeqPtr;

        if (pushReg[1] matches tagged Valid .pushVal) begin
            dataVec[enqPtrReg] <= pushVal;
            // $display(
            //     "time=%0t: push into ScanFIFOF, enqPtrReg=%h, itemCnt=%0d",
            //     $time, enqPtrReg, itemCnt
            // );
        end

        if (popReg[1]) begin
            // $display(
            //     "time=%0t: pop from ScanFIFOF, deqPtrReg=%h, emptyReg=",
            //     $time, deqPtrReg, fshow(emptyReg)
            // );
        end
        // $display("time=%0t: qSz=%0d, cntSz=%0d", $time, valueOf(qSz), valueOf(cntSz));

        enqPtrReg <= nextEnqPtr;
        deqPtrReg <= nextDeqPtr;

        let nextFull  = fullReg;
        let nextEmpty = emptyReg;
        if (!hasPush && hasPop) begin
            itemCnt.decr(1);
            nextEmpty = isAlmostEmpty;
            nextFull  = False;
            // $display("time=%0d:", $time, " itemCnt=%0d decr(1)", itemCnt);
        end
        else if (hasPush && !hasPop) begin
            itemCnt.incr(1);
            nextFull  = isAlmostFull;
            nextEmpty = False;
            // $display("time=%0d:", $time, " itemCnt=%0d incr(1)", itemCnt);
        end
        fullReg  <= nextFull;
        emptyReg <= nextEmpty;

        // $display(
        //     "time=%0t:", $time,
        //     " itemCnt=%0d, enqPtrReg=%0d, deqPtrReg=%0d, nextEnqPtr=%0d, nextDeqPtr=%0d",
        //     itemCnt, enqPtrReg, deqPtrReg, nextEnqPtr, nextDeqPtr,
        //     ", hasPush=", fshow(hasPush), ", hasPop=", fshow(hasPop),
        //     ", nextFull=", fshow(nextFull), ", nextEmpty=", fshow(nextEmpty),
        //     ", isFull=", fshow(isFull), ", isEmpty=", fshow(isEmpty)
        // );

        pushReg[1] <= tagged Invalid;
        popReg[1]  <= False;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule fifoMode if (!clearReg[1] && inFifoMode);
        if (preScanStartReg[1]) begin // startPreScan
            immAssert(
                !isEmpty,
                "isEmpty assertion @ mkScanFIFOF",
                $format("cannot start preScan when isEmpty=", fshow(isEmpty))
            );
            immAssert(
                !popReg[1],
                "no pop when startPreScan assertion @ mkScanFIFOF",
                $format(
                    "popReg[1]=", fshow(popReg[1]),
                    " should be false when preScanStartReg[1]=", fshow(preScanStartReg[1])
                )
            );
            scanStateReg <= SCAN_Q_PRE_SCAN_MODE;
            // $display(
            //     "time=%0t:", $time,
            //     " fifoMode change to state=", fshow(SCAN_Q_PRE_SCAN_MODE)
            // );
        end

        scanOutQ.clear;
        headReg <= tagged Invalid;
        preScanStartReg[1] <= False;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule preScanMode if (!clearReg[1] && inPreScanMode);
        immAssert(
            !isEmpty,
            "isEmpty assertion @ mkScanFIFOF",
            $format(
                "isEmpty=", fshow(isEmpty),
                " should be false when inPreScanMode"
            )
        );
        immAssert(
            !popReg[1],
            "no pop when inPreScanMode assertion @ mkScanFIFOF",
            $format(
                "popReg[1]=", fshow(popReg[1]),
                " should be false when preScanStartReg[1]=", fshow(preScanStartReg[1])
            )
        );

        if (scanStartReg[1]) begin // startScan
            scanStateReg <= SCAN_Q_SCAN_MODE;
            // $display(
            //     "time=%0t:", $time,
            //     " preScanMode change to state=", fshow(SCAN_Q_SCAN_MODE)
            // );
        end
        scanPtrReg        <= deqPtrReg;
        scanCnt           <= itemCnt;
        scanAlmostDoneReg <= isOne(itemCnt);
        scanStartReg[1]   <= False;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule scanModeStateChange if (!clearReg[1] && inScanMode);
        immAssert(
            !isEmpty,
            "isEmpty assertion @ mkScanFIFOF",
            $format("cannot scan next when isEmpty=", fshow(isEmpty))
        );

        if (scanStopReg[1]) begin // stopScan
            scanStateReg <= SCAN_Q_FIFOF_MODE;
            scanOutQ.clear;
            // $display(
            //     "time=%0t:", $time,
            //     " scanModeStateChange change to state=", fshow(SCAN_Q_FIFOF_MODE)
            // );
        end
        else if (preScanRestartReg[1]) begin // preScanRestart
            immAssert(
                !popReg[1],
                "no pop when preScanRestart assertion @ mkScanFIFOF",
                $format(
                    "popReg[1]=", fshow(popReg[1]),
                    " should be false when preScanRestartReg[1]=", fshow(preScanRestartReg[1])
                )
            );
            scanStateReg <= SCAN_Q_PRE_SCAN_MODE;
            scanOutQ.clear;
            // $display(
            //     "time=%0t:", $time,
            //     " scanModeStateChange change to state=", fshow(SCAN_Q_PRE_SCAN_MODE)
            // );
        end
        else if (scanDoneReg[1]) begin // scanDone
            scanStateReg <= SCAN_Q_FIFOF_MODE;
            // $display(
            //     "time=%0t:", $time,
            //     " scanModeStateChange change to state=", fshow(SCAN_Q_FIFOF_MODE)
            // );
        end

        scanStopReg[1] <= False;
        preScanRestartReg[1] <= False;
        scanDoneReg[1] <= False;
    endrule

    (* fire_when_enabled *)
    rule scanNext if (!clearReg[1] && inScanMode);
        scanCnt.decr(1);
        scanPtrReg <= scanPtrReg + 1;

        scanAlmostDoneReg <= isTwo(scanCnt);
        scanDoneReg[0]    <= scanAlmostDoneReg;

        let scanOutElem = case (headReg) matches
            tagged Valid .modifiedHead: modifiedHead;
            default: dataVec[scanPtrReg];
        endcase;

        scanOutQ.enq(scanOutElem);
        headReg <= tagged Invalid;
        // $display(
        //     "time=%0t:", $time,
        //     " scanNext, scanPtrReg=%0d, itemCnt=%0d",
        //     scanPtrReg, itemCnt
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule check if (!clearReg[1]);
        immAssert(
            !(scanStartReg[1] && popReg[1]),
            "scanStartReg and popReg assertion @ mkScanFIFOF",
            $format(
                "scanStartReg=", fshow(scanStartReg[1]),
                ", popReg=", fshow(popReg[1]),
                " cannot both be true"
            )
        );
        immAssert(
            !(preScanRestartReg[1] && popReg[1]),
            "preScanRestartReg and popReg assertion @ mkScanFIFOF",
            $format(
                "preScanRestartReg=", fshow(preScanRestartReg[1]),
                ", popReg=", fshow(popReg[1]),
                " cannot both be true"
            )
        );

        if (inScanMode || inPreScanMode) begin
            immAssert(
                !isZero(itemCnt),
                "notEmpty assertion @ mkScanFIFOF",
                $format(
                    "itemCnt=%0d", itemCnt,
                    " cannot be zero when scanStateReg=",
                    fshow(scanStateReg)
                )
            );
        end

        if (isEmpty) begin
            immAssert(
                isZero(itemCnt),
                "isEmpty assertion @ mkScanFIFOF",
                $format(
                    "itemCnt=%0d should be zero when isEmpty=",
                    itemCnt, fshow(isEmpty)
                )
            );
        end
        else if (isFull) begin
            immAssert(
                itemCnt == fromInteger(valueOf(qSz)),
                "isFull assertion @ mkScanFIFOF",
                $format(
                    "itemCnt=%0d should == qSz=%0d when isFull=",
                    itemCnt, valueOf(qSz), fshow(isFull)
                )
            );
        end

        // Verify deqPtrReg cannot over pass scanPtrReg when in scan mode
        if (inScanMode) begin
            // if (popReg[1] && !scanNextReg[1]) begin
            if (popReg[1]) begin
                immAssert(
                    deqPtrReg != scanPtrReg + 1,
                    "dequeue beyond scan assertion @ mkScanFIFOF",
                    $format(
                        "deqPtrReg=%0d should != scanPtrReg=%0d + 1",
                        deqPtrReg, scanPtrReg,
                        " when enqPtrReg=%0d", enqPtrReg,
                        ", scanStateReg=", fshow(scanStateReg),
                        ", popReg=", fshow(popReg[1]),
                        ", hasPush=", fshow(isValid(pushReg[1])),
                        ", scanCnt=%0d", scanCnt,
                        // ", scanNextReg=", fshow(scanNextReg[1]),
                        ", isEmpty=", fshow(isEmpty),
                        ", isFull=", fshow(isFull)
                    )
                );
            end

            immAssert(
                !(scanStopReg[1] && preScanRestartReg[1]),
                "scanStopReg and preScanRestartReg assertion @ mkScanFIFOF",
                $format(
                    "scanStopReg=", fshow(scanStopReg[1]),
                    ", preScanRestartReg=", fshow(preScanRestartReg[1]),
                    " cannot both be true"
                )
            );
        end

        if (inPreScanMode) begin
            // immAssert(
            //     !isZero(scanCnt),
            //     "scanCnt assertion @ mkScanFIFOF",
            //     $format(
            //         "scanCnt=%0d", scanCnt,
            //         " cannot be zero when scanStateReg=",
            //         fshow(scanStateReg)
            //     )
            // );
            immAssert(
                !popReg[1],
                "no pop when inPreScanMode assertion @ mkScanFIFOF",
                $format(
                    "popReg[1]=", fshow(popReg[1]),
                    " should be false when inPreScanMode=", fshow(inPreScanMode)
                )
            );
        end

        immAssert(
            fromInteger(valueOf(qSz)) >= itemCnt && itemCnt >= scanCnt,
            "itemCnt >= scanCnt assertion @ mkScanFIFOF",
            $format(
                "valueOf(qSz)=%0d should >= itemCnt=%0d",
                valueOf(qSz), itemCnt,
                " and itemCnt=%0d should >= scanCnt=%0d",
                itemCnt, scanCnt
            )
        );
    endrule

    interface fifof = interface FIFOF#(qSz, anytype);
        method anytype first() if (!isEmpty);
            return dataVec[deqPtrReg];
        endmethod

        method Bool notEmpty() = !isEmpty;
        method Bool notFull()  = !isFull;

        method Action enq(anytype inputVal) if (!isFull && inFifoMode);
            pushReg[0] <= tagged Valid inputVal;
            // $display("time=%0t:", $time, " ScanFIFOF enq()");
        endmethod

        // It can dequeue when inFifoMode and inScanMode, but not inPreScanMode
        method Action deq() if (!isEmpty && (inFifoMode || inScanMode));
            // Make sure no dequeue when scan start or scan restart
            immAssert(
                !scanStartReg[1] && !preScanRestartReg[1],
                "dequeue assertion @ mkScanFIFOF",
                $format(
                    "cannot dequeue when scanStartReg=", fshow(scanStartReg[1]),
                    " or preScanRestartReg=", fshow(preScanRestartReg[1])
                )
            );

            popReg[0] <= True;
            // $display("time=%0t:", $time, " ScanFIFOF deq()");
        endmethod

        method Action clear();
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface scanCntrl = interface ScanCntrl;
        method anytype getHead() if (inPreScanMode);
            return dataVec[deqPtrReg];
        endmethod

        method Action modifyHead(anytype head) if (inPreScanMode);
            headReg <= tagged Valid head;
            // headReg[0] <= tagged Valid head;
        endmethod

        method Action preScanStart() if (inFifoMode);
            preScanStartReg[0] <= True;
        endmethod

        method Action scanStart() if (inPreScanMode);
            scanStartReg[0] <= True;
            // $display(
            //     "time=%0t: scanStart(), scanPtrReg=%0d, deqPtrReg=%0d, enqPtrReg=%0d",
            //     $time, scanPtrReg, deqPtrReg, enqPtrReg,
            //     ", scanStateReg=", fshow(scanStateReg),
            //     ", emptyReg=", fshow(emptyReg)
            // );
        endmethod

        method Action scanStop() if (inScanMode);
            scanStopReg[0] <= True;
        endmethod

        method Action preScanRestart() if (inScanMode);
            preScanRestartReg[0] <= True;
            immAssert(
                !isEmpty,
                "isEmpty assertion @ mkScanFIFOF",
                $format("cannot restart scan when isEmpty=", fshow(isEmpty))
            );
        endmethod

        method Action clear();
            clearReg[0] <= True;
        endmethod

        method Bool hasScanOut() = !inFifoMode || scanOutQ.notEmpty;
        method Bool isScanDone() = inFifoMode;
        // method Bool isScanMode() = inScanMode;
    endinterface;

    interface scanPipeOut = f_FIFOF_to_PipeOut(scanOutQ);

    method UInt#(cntSz) size() = unpack(itemCnt);
endmodule

interface SearchIfc2#(type anytype);
    method Maybe#(anytype) search(function Bool searchFunc(anytype fifoItem));
endinterface

interface SearchFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifof;
    interface SearchIfc2#(anytype) searchIfc;
endinterface

module mkSearchFIFOF(SearchFIFOF#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(qSz), qLogSz),
    NumAlias#(TAdd#(qLogSz, 1), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype))     dataVec <- replicateM(mkRegU);
    Vector#(qSz, Array#(Reg#(Bool))) tagVec <- replicateM(mkCReg(3, False));
    Reg#(Bit#(cntSz)) enqPtrReg[3] <- mkCReg(3, 0);
    Reg#(Bit#(cntSz)) deqPtrReg[3] <- mkCReg(3, 0);
    Reg#(Bool)         emptyReg[3] <- mkCReg(3, True);
    Reg#(Bool)          fullReg[3] <- mkCReg(3, False);

    function Bool predFunc(
        function Bool searchFunc(anytype fifoItem),
        Tuple2#(Array#(Reg#(Bool)), Reg#(anytype)) zipItem
    );
        let { tag, anydata } = zipItem;
        return tag[0] && searchFunc(readReg(anydata));
    endfunction

    function Bool isFull(
        Bit#(cntSz) nextEnqPtr, Bit#(cntSz) nextDeqPtr
    ) provisos(Add#(1, anysize, cntSz));
        return (msb(nextEnqPtr) != msb(nextDeqPtr)) &&
            (removeMSB(nextEnqPtr) == removeMSB(nextDeqPtr));
    endfunction

    function Action clearTag(Array#(Reg#(Bool)) tagReg);
        action
            tagReg[2] <= False;
        endaction
    endfunction

    interface fifof = interface FIFOF#(qSz, anytype);
        method anytype first() if (!emptyReg[0]);
            return dataVec[removeMSB(deqPtrReg[0])];
        endmethod

        method Bool notEmpty() = !emptyReg[0];
        method Bool notFull()  = !fullReg[1];

        method Action enq(anytype inputVal) if (!fullReg[1]);
            dataVec[removeMSB(enqPtrReg[1])]   <= inputVal;
            tagVec[removeMSB(enqPtrReg[1])][1] <= True;
            let nextEnqPtr = enqPtrReg[1] + 1;
            enqPtrReg[1] <= nextEnqPtr;
            fullReg[1]   <= isFull(nextEnqPtr, deqPtrReg[1]);
            emptyReg[1]  <= False;
        endmethod

        method Action deq() if (!emptyReg[0]);
            tagVec[removeMSB(deqPtrReg[0])][0] <= False;
            let nextDeqPtr = deqPtrReg[0] + 1;
            deqPtrReg[0] <= nextDeqPtr;
            emptyReg[0]  <= nextDeqPtr == enqPtrReg[0];
            fullReg[0]   <= False;
        endmethod

        method Action clear();
            mapM_(clearTag, tagVec);
            // for (Integer idx = 0; idx < valueOf(qSz); idx = idx + 1) begin
            //     tagVec[idx][2] <= False;
            // end
            enqPtrReg[2] <= 0;
            deqPtrReg[2] <= 0;
            emptyReg[2]  <= True;
            fullReg[2]   <= False;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc2#(anytype);
        method Maybe#(anytype) search(function Bool searchFunc(anytype fifoItem));
            let zipVec = zip(tagVec, dataVec);
            let maybeFindResult = findIndex(predFunc(searchFunc), zipVec);
            if (maybeFindResult matches tagged Valid .index) begin
                // let tag = readReg(tagVec[index]);
                // immAssert(
                //     tag,
                //     "tag assertion @ mkSearchFIFOF",
                //     $format("search found tag=", fshow(tag), " must be true")
                // );
                return tagged Valid readReg(dataVec[index]);
            end
            else begin
                return tagged Invalid;
            end
        endmethod
    endinterface;
endmodule

interface SearchIfc#(type anytype);
    method Action searchReq(anytype item2Search);
    method ActionValue#(Maybe#(anytype)) searchResp();
endinterface

interface CacheIfc#(type anytype);
    method Action push(anytype inputVal);
    method Action clear();
endinterface

interface CacheFIFO#(numeric type qSz, type anytype);
    interface CacheIfc#(anytype) cacheIfc;
    interface SearchIfc#(anytype) searchIfc;
endinterface

module mkCacheFIFO2#(
    function cmpResultType compareFunc(anytype item4Search, anytype itemInQ),
    function Bool checkCompareResult(cmpResultType searchResult),
    function anytype compareResult2SearchResp(cmpResultType searchResult)
)(CacheFIFO#(qSz, anytype)) provisos(
    Bits#(anytype, tSz),
    Bits#(cmpResultType, cmpResultTypeSz),
    NumAlias#(TLog#(qSz), cntSz),
    Add#(TLog#(qSz), 1, TLog#(TAdd#(qSz, 1))) // qSz must be power of 2
);
    Vector#(qSz, Reg#(anytype)) dataVec <- replicateM(mkRegU);
    Vector#(qSz, Reg#(Bool))     tagVec <- replicateM(mkReg(False));
    let zipVec = zip(readVReg(tagVec), readVReg(dataVec));

    FIFOF#(anytype)          searchReqQ <- mkFIFOF;
    FIFOF#(Maybe#(anytype)) searchRespQ <- mkFIFOF;

    FIFOF#(Tuple2#(Bool, Vector#(qSz, Tuple2#(Bool, cmpResultType)))) searchStageQ <- mkFIFOF;
    // FIFOF#(Tuple2#(Bool, Maybe#(Tuple2#(Bool, cmpResultType)))) searchResultQ <- mkFIFOF;
    FIFOF#(Tuple3#(Bool, Vector#(qSz, Tuple2#(Bool, cmpResultType)), Maybe#(UInt#(cntSz)))) searchResultQ <- mkFIFOF;

    Reg#(Maybe#(anytype))   pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             clearReg[2] <- mkCReg(2, False);

    Reg#(Bit#(cntSz)) enqPtrReg <- mkReg(0);

    function Tuple2#(Bool, cmpResultType) mapFunc(
        function cmpResultType compareFunc(anytype item4Search, anytype itemInQ),
        anytype item2Search,
        Tuple2#(Bool, anytype) zipItem
    );
        let { tag, itemInQ } = zipItem;
        return tuple2(tag, compareFunc(item2Search, itemInQ));
    endfunction

    function Bool findFunc(
        function Bool checkCompareResult(cmpResultType searchResult),
        Tuple2#(Bool, cmpResultType) zipItem
    );
        let { tag, searchResult } = zipItem;
        return tag && checkCompareResult(searchResult);
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule push;
        if (clearReg[1]) begin
            writeVReg(tagVec, replicate(False));
            enqPtrReg <= 0;
        end
        else begin
            if (pushReg[1] matches tagged Valid .pushVal) begin
                dataVec[enqPtrReg] <= pushVal;
                tagVec[enqPtrReg]  <= True;

                enqPtrReg <= enqPtrReg + 1;
            end
        end

        clearReg[1] <= False;
        pushReg[1]  <= tagged Invalid;
    endrule

    rule handleSearchReq;
        let maybePushValCmpResult = tagged Invalid;

        let item2Search = searchReqQ.first;
        searchReqQ.deq;

        let searchResultVec = map(mapFunc(compareFunc, item2Search), zipVec);

        searchStageQ.enq(tuple2(clearReg[1], searchResultVec));
    endrule

    rule checkMapResult;
        let { hasClear, searchResultVec } = searchStageQ.first;
        searchStageQ.deq;

        // let maybeFindResult = find(findFunc(checkCompareResult), searchResultVec);
        // searchResultQ.enq(tuple2(hasClear || clearReg[1], maybeFindResult));

        let maybeFindIndex = findIndex(findFunc(checkCompareResult), searchResultVec);
        searchResultQ.enq(tuple3(hasClear || clearReg[1], searchResultVec, maybeFindIndex));
    endrule

    rule handleSearchResp;
        // let { hasClear, maybeFindResult } = searchResultQ.first;
        let { hasClear, searchResultVec, maybeFindIndex } = searchResultQ.first;
        searchResultQ.deq;

        let searchResp = tagged Invalid;
        if (!hasClear && !clearReg[1]) begin
            // if (maybeFindResult matches tagged Valid .findResult) begin
            //     searchResp = tagged Valid compareResult2SearchResp(getTupleSecond(findResult));
            // end
            if (maybeFindIndex matches tagged Valid .findIndex) begin
                let findResult = searchResultVec[findIndex];
                searchResp = tagged Valid compareResult2SearchResp(getTupleSecond(findResult));
            end
        end
        searchRespQ.enq(searchResp);
    endrule

    interface cacheIfc = interface CacheIfc#(anytype);
        method Action push(anytype pushVal);
            pushReg[0] <= tagged Valid pushVal;
        endmethod

        method Action clear();
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface searchIfc = interface SearchIfc#(anytype);
        method Action searchReq(anytype item2Search);
            searchReqQ.enq(item2Search);
            // searchReg[0] <= tagged Valid item2Search;
        endmethod

        method ActionValue#(Maybe#(anytype)) searchResp();
            let maybeFindResult = searchRespQ.first;
            searchRespQ.deq;
            return maybeFindResult;
        endmethod
    endinterface;
endmodule
