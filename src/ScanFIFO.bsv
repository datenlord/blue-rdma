interface ScanFIFO#(type a_type, numeric type fifoDepth) ;
    method Action enq(a_type sendData) ;
    method Action deq();
    method a_type first() ;

    method Bool notFull ;
    method Bool notEmpty ;

    method UInt#(TLog#(TAdd#(fifoDepth, 1))) count;

    method Action scanStart();
    method a_type scanCurrent();
    method Action scanNext();
    method Bool scanDone();

    method Action clear();
endinterface

module mkScanFIFO(ScanFIFO#(n, t)) provisos(
    Bits#(t, tSz),
    NumAlias#(TLog#(TAdd#(n, 1)), cntSz)
);
    // n is size of fifo
    // t is data type of fifo
    Vector#(n, Reg#(t))  data     <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(n))) enqP     <- mkReg(0);
    Reg#(Bit#(TLog#(n))) deqP     <- mkReg(0);
    Reg#(Bool)           empty    <- mkReg(True);
    Reg#(Bool)           full     <- mkReg(False);
    Reg#(UInt#(cntSz))   cnt      <- mkReg(0);
    Reg#(Bit#(TLog#(n))) scanP    <- mkRegU;
    Reg#(Bool)           scanMode <- mkReg(False);
    Bit#(TLog#(n))       maxIndex = fromInteger(valueOf(n) - 1);

    method UInt#(cntSz) count = cnt;

    method Action scanStart() if (!scanMode);
        if (!emtpy) begin
            scanMode <= True;
            scanP <= deqP;
        end
    endmethod

    method t scanCurrent() if (scanMode);
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

    method Action enq(t x) if (!full);
        cnt <= cnt + 1;
        data[enqP] <= x;
        empty <= False;
        let next_enqP = (enqP == maxIndex) ? 0 : enqP + 1;
        if (next_enqP == deqP) begin
            full <= True;
        end
        enqP <= next_enqP;
    endmethod

    method Bool notEmpty = !empty;

    method Action deq if (!empty);
        cnt <= cnt - 1;
        // Tell later stages a dequeue was requested
        full <= False;
        let next_deqP = (deqP == maxIndex) ? 0 : deqP + 1;
        if (next_deqP == enqP) begin
            empty <= True;
        end
        deqP <= next_deqP;
    endmethod

    method t first if (!empty);
        return data[deqP];
    endmethod

    (* descending_urgency="clear, deq, enq" *)
    method Action clear;
        cnt   <= 0;
        enqP  <= 0;
        deqP  <= 0;
        empty <= True;
        full  <= False;
    endmethod
endmodule
