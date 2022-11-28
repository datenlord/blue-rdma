import Cntrs :: *;
import FIFOF :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Headers :: *;
import DataTypes :: *;
import Utils :: *;

typedef 100000 MAX_CYCLES;

function ByteEnBitNum calcByteEnBitNum(ByteEn fragByteEn);
    let reversedByteEn = reverseBits(fragByteEn);
    ByteEnBitNum byteEnBitNum = 0;
    // Bool matched = False;
    for (
        ByteEnBitNum idx = 0;
        idx <= fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        idx = idx + 1
    ) begin
        if (reversedByteEn == ((1 << idx) - 1)) begin
            byteEnBitNum = idx;
            // matched = True;
        end
    end
    // $display("matched=%b, reversedByteEn=%h", matched, reversedByteEn);
    return byteEnBitNum;
endfunction

module mkCountDown(Empty);
    let cntr <- mkUCount(0, valueOf(MAX_CYCLES));

    rule count;
        cntr.incr(1);

        if (cntr.isEqual(valueOf(MAX_CYCLES))) begin
            // error("elab err msg");
            // $info("info: %0d", 1);
            // $warning("warning: %0d", 2);
            // $error("error: %0d", 3);
            // $fatal(2, "fatal @ %m time=%0d", $time);
            $info("time=%0d: finished after %0d cycles", $time, valueOf(MAX_CYCLES));
            $finish(0);
        end
    endrule
endmodule
/*
module mkRandomPipeOut(PipeOut#(a)) provisos(Bits#(a, aSz), Bounded#(a));
    Randomize#(a) randomGen <- mkGenericRandomizer;
    FIFOF#(a) randomValQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let val <- randomGen.next;
        randomValQ.enq(val);
    endrule

    return convertFifo2PipeOut(randomValQ);
endmodule

module mkRandomFromRangePipeOut#(
    a minInclusive, a maxInclusive
)(Tuple2#(PipeOut#(a), PipeOut#(a))) provisos(Bits#(a, aSz), Bounded#(a));
    FIFOF#(a) randomValQ <- mkFIFOF;
    Randomize#(a) randomGen <-
        mkConstrainedRandomizer(minInclusive, maxInclusive);
    let tuplePipeOut <- mkForkAndBufferRight(convertFifo2PipeOut(randomValQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule enq if (initializedReg);
        let randomVal <- randomGen.next;
        randomValQ.enq(randomVal);
        // $display("time=%0d: randomVal=%0d", $time, randomVal);
    endrule

    return tuplePipeOut;
endmodule
*/

module mkRandomHeaderDataPipeOut(PipeOut#(HeaderData));
    Randomize#(HeaderData) randomHeaderDataGen <- mkGenericRandomizer;
    FIFOF#(HeaderData) headerDataQ <- mkFIFOF;
    // Vector#(vsize, PipeOut#(HeaderData)) resultPipeOut <-
    //     mkForkVector(convertFifo2PipeOut(headerDataQ));

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomHeaderDataGen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let headerData <- randomHeaderDataGen.next;
        headerDataQ.enq(headerData);
    endrule

    return convertFifo2PipeOut(headerDataQ);
endmodule

module mkRandomLenPipeOut#(
    Length minLength, Length maxLength
)(PipeOut#(Length));
    Randomize#(Length) randomLen <- mkConstrainedRandomizer(minLength, maxLength);
    FIFOF#(Length) lenQ <- mkFIFOF;

    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule gen if (initializedReg);
        let len <- randomLen.next;
        lenQ.enq(len);
    endrule

    return convertFifo2PipeOut(lenQ);
endmodule

module mkRandomHeaderLenPipeOut#(
    HeaderByteNum minHeaderLen, HeaderByteNum maxHeaderLen
)(Vector#(vsize, PipeOut#(HeaderByteNum)));
// )(Tuple2#(PipeOut#(HeaderByteNum), PipeOut#(HeaderByteNum)));
    FIFOF#(HeaderByteNum) headerLenQ <- mkFIFOF;
    Randomize#(HeaderByteNum) randomHeaderLen <-
        mkConstrainedRandomizer(minHeaderLen, maxHeaderLen);
    Vector#(vsize, PipeOut#(HeaderByteNum)) resultPipeOut <-
        mkForkVector(convertFifo2PipeOut(headerLenQ));
    // let resultPipeOut <- mkForkAndBufferRight(convertFifo2PipeOut(headerLenQ));
    Reg#(Bool) initializedReg <- mkReg(False);

    rule init if (!initializedReg);
        randomHeaderLen.cntrl.init;
        initializedReg <= True;
    endrule

    rule enq if (initializedReg);
        let headerLen <- randomHeaderLen.next;
        headerLenQ.enq(headerLen);
        // $display("time=%0d: headerLen=%0d", $time, headerLen);
    endrule

    return resultPipeOut;
endmodule
