import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;

interface ScanIfc#(numeric type qSz, type anytype);
    method Action scanStart();
    method anytype current();
    method Action scanNext();
    method Bool scanDone();
    method UInt#(TLog#(TAdd#(qSz, 1))) count;
endinterface

interface ScanFIFOF#(numeric type qSz, type anytype);
    interface FIFOF#(anytype) fifoF;
    interface ScanIfc#(qSz, anytype) scanIfc;
    // method Action enq(anytype inputVal);
    // method Action deq();
    // method anytype first();

    // method Bool notFull;
    // method Bool notEmpty;

    // method Action clear();
endinterface

// (* descending_urgency="clear, deq, enq" *)
module mkScanFIFOF(ScanFIFOF#(vSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(TAdd#(vSz, 1)), cntSz)
);
    Vector#(vSz, Reg#(anytype)) dataVec <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(vSz)))    enqPtrReg <- mkReg(0);
    Reg#(Bit#(TLog#(vSz)))    deqPtrReg <- mkReg(0);
    Reg#(Bool)                 emptyReg <- mkReg(True);
    Reg#(Bool)                  fullReg <- mkReg(False);
    Reg#(UInt#(cntSz))           cntReg <- mkReg(0);
    Reg#(Bit#(TLog#(vSz)))   scanPtrReg <- mkRegU;
    Reg#(Bool)              scanModeReg <- mkReg(False);
    Bit#(TLog#(vSz))        maxIndex  = fromInteger(valueOf(vSz) - 1);

    interface scanIfc = interface ScanIfc#(vSz, anytype);
        method Action scanStart() if (!scanModeReg);
            dynAssert(
                !emptyReg,
                "emptyReg assertion @ mkScanFIFOF",
                $format("cannot start scan when emptyReg=", fshow(emptyReg))
            );

            if (!emptyReg) begin
                scanModeReg <= True;
                scanPtrReg <= deqPtrReg;
            end
        endmethod

        method anytype current() if (scanModeReg);
            return dataVec[scanPtrReg];
        endmethod

        method Action scanNext if (scanModeReg);
            let nextScanP = scanPtrReg + 1;
            if (nextScanP == enqPtrReg) begin
                scanModeReg <= False;
            end
            scanPtrReg <= nextScanP;
        endmethod

        method Bool scanDone() = !scanModeReg;
        method UInt#(cntSz) count = cntReg;
    endinterface;

    interface fifoF = interface FIFOF#(vSz, anytype);
        method Action enq(anytype inputVal) if (!fullReg && !scanModeReg);
            cntReg <= cntReg + 1;
            dataVec[enqPtrReg] <= inputVal;
            emptyReg <= False;
            let nextEnqPtr = (enqPtrReg == maxIndex) ? 0 : enqPtrReg + 1;
            if (nextEnqPtr == deqPtrReg) begin
                fullReg <= True;
            end
            enqPtrReg <= nextEnqPtr;
        endmethod

        method Action deq if (!emptyReg && !scanModeReg);
            cntReg <= cntReg - 1;
            // Tell later stages a dequeue was requested
            fullReg <= False;
            let nextDeqPtr = (deqPtrReg == maxIndex) ? 0 : deqPtrReg + 1;
            if (nextDeqPtr == enqPtrReg) begin
                emptyReg <= True;
            end
            deqPtrReg <= nextDeqPtr;
        endmethod

        method anytype first if (!emptyReg && !scanModeReg);
            return dataVec[deqPtrReg];
        endmethod

        method Bool notEmpty = !emptyReg;
        method Bool notFull  = !fullReg;

        method Action clear;
            cntReg    <= 0;
            enqPtrReg <= 0;
            deqPtrReg <= 0;
            emptyReg  <= True;
            fullReg   <= False;
        endmethod
    endinterface;
endmodule
