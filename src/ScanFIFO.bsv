import Vector :: *;

interface ScanFIFO#(numeric type vSz, type anytype);
    method Action enq(anytype inputVal);
    method Action deq();
    method anytype first();

    method Bool notFull;
    method Bool notEmpty;

    method UInt#(TLog#(TAdd#(vSz, 1))) count;

    method Action scanStart();
    method anytype scanCurrent();
    method Action scanNext();
    method Bool scanDone();

    method Action clear();
endinterface

(* descending_urgency="clear, deq, enq" *)
module mkScanFIFO(ScanFIFO#(vSz, anytype)) provisos(
    Bits#(anytype, tSz),
    NumAlias#(TLog#(TAdd#(vSz, 1)), cntSz)
);
    // vSz is size of fifo
    // anytype is data type of fifo
    Vector#(vSz, Reg#(anytype)) data <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(vSz)))      enqP <- mkReg(0);
    Reg#(Bit#(TLog#(vSz)))      deqP <- mkReg(0);
    Reg#(Bool)                 empty <- mkReg(True);
    Reg#(Bool)                  full <- mkReg(False);
    Reg#(UInt#(cntSz))           cnt <- mkReg(0);
    Reg#(Bit#(TLog#(vSz)))     scanP <- mkRegU;
    Reg#(Bool)              scanMode <- mkReg(False);
    Bit#(TLog#(vSz))        maxIndex = fromInteger(valueOf(vSz) - 1);

    method UInt#(cntSz) count = cnt;

    method Action scanStart() if (!scanMode && !empty);
        // if (!emtpy) begin
        scanMode <= True;
        scanP <= deqP;
        // end
    endmethod

    method anytype scanCurrent() if (scanMode);
        return data[scanP];
    endmethod

    method Action scanNext if (scanMode);
        let nextScanP = scanP + 1;
        if (nextScanP == enqP) begin
            scanMode <= False;
        end
        scanP <= nextScanP;
    endmethod

    method Bool scanDone() = !scanMode;

    method Bool notFull = !full;

    method Action enq(anytype inputVal) if (!full && !scanMode);
        cnt <= cnt + 1;
        data[enqP] <= inputVal;
        empty <= False;
        let next_enqP = (enqP == maxIndex) ? 0 : enqP + 1;
        if (next_enqP == deqP) begin
            full <= True;
        end
        enqP <= next_enqP;
    endmethod

    method Bool notEmpty = !empty;

    method Action deq if (!empty && !scanMode);
        cnt <= cnt - 1;
        // Tell later stages a dequeue was requested
        full <= False;
        let next_deqP = (deqP == maxIndex) ? 0 : deqP + 1;
        if (next_deqP == enqP) begin
            empty <= True;
        end
        deqP <= next_deqP;
    endmethod

    method anytype first if (!empty && !scanMode);
        return data[deqP];
    endmethod

    method Action clear;
        cnt   <= 0;
        enqP  <= 0;
        deqP  <= 0;
        empty <= True;
        full  <= False;
    endmethod
endmodule
