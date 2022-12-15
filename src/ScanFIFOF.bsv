import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;

function Bit#(1) getMSB(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    return (reverseBits(bits))[0];
endfunction

function Bit#(TSub#(nSz, 1)) removeMSB(Bit#(nSz) bits) provisos(Add#(1, kSz, nSz));
    return truncateLSB(bits << 1);
endfunction

// function PipeOut#(anytype) scanQ2PipeOut(ScanIfc scanQ);
//     return interface PipeOut;
//         method anytype first() = scanQ.current;
//         method Action deq() = scanQ.scanNext;
//         method Bool notEmpty() = !scanQ.scanDone;
//     endinterface;
// endfunction

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
endinterface

// (* descending_urgency="clear, deq, enq" *)
module mkScanFIFOF(ScanFIFOF#(vSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(vSz), vLogSz),
    NumAlias#(TAdd#(vLogSz, 1), cntSz),
    Add#(TLog#(vSz), 1, TLog#(TAdd#(vSz, 1))) // vSz must be power of 2
);
    Vector#(vSz, Reg#(anytype)) dataVec <- replicateM(mkRegU());
    Reg#(Bit#(cntSz))         enqPtrReg <- mkReg(0);
    Reg#(Bit#(cntSz))         deqPtrReg <- mkReg(0);
    Reg#(Bool)                 emptyReg <- mkReg(True);
    Reg#(Bool)                  fullReg <- mkReg(False);
    Reg#(UInt#(cntSz))           cntReg <- mkReg(0);
    Reg#(Bit#(cntSz))        scanPtrReg <- mkRegU;
    Reg#(Bool)              scanModeReg <- mkReg(False);

    // Bit#(TLog#(vSz))        maxIndex  = fromInteger(valueOf(vSz) - 1);

    Reg#(Maybe#(anytype)) pushReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool)             popReg[2] <- mkCReg(2, False);
    Reg#(Bool)           clearReg[2] <- mkCReg(2, False);

    function Bool isFull(Bit#(cntSz) nextEnqPtr);
        return (getMSB(nextEnqPtr) != getMSB(deqPtrReg)) &&
            (removeMSB(nextEnqPtr) == removeMSB(deqPtrReg));
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        if (clearReg[1]) begin
            cntReg    <= 0;
            enqPtrReg <= 0;
            deqPtrReg <= 0;
            emptyReg  <= True;
            fullReg   <= False;
        end
        else begin
            let nextEnqPtr = enqPtrReg;
            let nextDeqPtr = deqPtrReg;

            if (pushReg[1] matches tagged Valid .pushVal) begin
                dataVec[removeMSB(enqPtrReg)] <= pushVal;
                nextEnqPtr = enqPtrReg + 1;
                // $display("time=%0d: push into ScanFIFOF, enqPtrReg=%h", $time, enqPtrReg);
            end

            if (popReg[1]) begin
                nextDeqPtr = deqPtrReg + 1;
                // $display(
                //     "time=%0d: pop from ScanFIFOF, deqPtrReg=%h, emptyReg=",
                //     $time, deqPtrReg, fshow(emptyReg)
                // );
            end

            if (isValid(pushReg[1]) && !popReg[1]) begin
                cntReg <= cntReg + 1;
            end
            else if (!isValid(pushReg[1]) && popReg[1]) begin
                cntReg <= cntReg - 1;
            end

            fullReg  <= isFull(nextEnqPtr);
            emptyReg <= nextDeqPtr == enqPtrReg;

            enqPtrReg <= nextEnqPtr;
            deqPtrReg <= nextDeqPtr;

            // $display(
            //     "time=%0d: enqPtrReg=%0d, deqPtrReg=%0d", $time, enqPtrReg, deqPtrReg,
            //     ", fullReg=", fshow(fullReg), ", emptyReg=", fshow(emptyReg)
            // );
        end

        clearReg[1] <= False;
        pushReg[1]  <= tagged Invalid;
        popReg[1]   <= False;
    endrule

    interface fifoF = interface FIFOF#(vSz, anytype);
        method anytype first if (!emptyReg && !scanModeReg);
            return dataVec[removeMSB(deqPtrReg)];
        endmethod

        method Bool notEmpty = !emptyReg;
        method Bool notFull  = !fullReg;

        method Action enq(anytype inputVal) if (!fullReg && !scanModeReg);
            pushReg[0] <= tagged Valid inputVal;
        endmethod

        method Action deq if (!emptyReg && !scanModeReg);
            popReg[0] <= True;
        endmethod

        method Action clear() if (!scanModeReg);
            clearReg[0] <= True;
        endmethod
    endinterface;

    interface scanIfc = interface ScanIfc#(vSz, anytype);
        method Action scanStart() if (!scanModeReg);
            dynAssert(
                !emptyReg,
                "emptyReg assertion @ mkScanFIFOF",
                $format("cannot start scan when emptyReg=", fshow(emptyReg))
            );

            scanModeReg <= !emptyReg;
            scanPtrReg <= deqPtrReg;

            // $display(
            //     "time=%0d: scanStart(), scanPtrReg=%0d, deqPtrReg=%0d, enqPtrReg=%0d",
            //     $time, scanPtrReg, deqPtrReg, enqPtrReg,
            //     ", scanModeReg=", fshow(scanModeReg),
            //     ", emptyReg=", fshow(emptyReg)
            // );
        endmethod

        method anytype current() if (scanModeReg);
            return dataVec[removeMSB(scanPtrReg)];
        endmethod

        method Action scanNext if (scanModeReg);
            let nextScanPtr = scanPtrReg + 1;
            let scanFinish = nextScanPtr == enqPtrReg;
            scanPtrReg  <= nextScanPtr;
            scanModeReg <= !scanFinish;
            // $display(
            //     "time=%0d: scanPtrReg=%0d, nextScanPtr=%0d, enqPtrReg=%0d, deqPtrReg=%0d, scanModeReg=",
            //     $time, scanPtrReg, nextScanPtr, enqPtrReg, deqPtrReg, fshow(scanModeReg)
            // );
        endmethod

        method Bool scanDone() = !scanModeReg;
        method UInt#(cntSz) count = cntReg;
    endinterface;
endmodule
