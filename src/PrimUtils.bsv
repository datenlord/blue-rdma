import Cntrs :: *;

typedef 2 TWO;

function Bool isZero(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    // TODO: consider using fold
    Bool ret = unpack(|bits);
    return !ret;
endfunction

function Bool isLessOrEqOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = isZero(bits >> 1);
    // Bool ret = isZero(bits >> 1) && unpack(bits[0]);
    return ret;
endfunction

function Bool isOne(Bit#(nSz) bits) provisos(Add#(1, anysize, nSz));
    return isLessOrEqOne(bits) && unpack(lsb(bits));
endfunction

function Bool isTwo(Bit#(nSz) bits) provisos(Add#(2, anysize, nSz));
    return isZero(bits >> 2) && unpack(bits[1]) && !unpack(lsb(bits));
endfunction

function Bool isAllOnes(Bit#(nSz) bits);
    Bool ret = unpack(&bits);
    return ret;
endfunction

function Bool isLargerThanOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return !isZero(bits >> 1);
endfunction

// 64 >= nSz >= 32
function Tuple2#(Bool, Bool) isZero4LargeBits(Bit#(nSz) bits) provisos(
    Add#(32, anysizeJ, nSz),
    Add#(nSz, anysizeK, 64),
    NumAlias#(TDiv#(nSz, 2), lowPartSz),
    NumAlias#(TSub#(nSz, lowPartSz), highPartSz),
    Add#(anysizeL, TDiv#(nSz, 2), nSz),
    // Add#(1, anysizeM, TDiv#(nSz, 2)),
    // Add#(1, anysizeN, TSub#(nSz, TDiv#(nSz, 2))),
    Add#(lowPartSz, highPartSz, nSz)
);
    Bit#(lowPartSz)   lowPartBits = truncate(bits);
    Bit#(highPartSz) highPartBits = truncateLSB(bits);
    let isLowPartZero  = isZero(lowPartBits);
    let isHighPartZero = isZero(highPartBits);
    return tuple2(isHighPartZero, isLowPartZero);
endfunction

function Bit#(nSz) zeroExtendLSB(Bit#(mSz) bits) provisos(Add#(mSz, anysize, nSz));
    return { bits, 0 };
endfunction

function Bit#(TSub#(nSz, 1)) removeMSB(Bit#(nSz) bits) provisos(Add#(1, anysize, nSz));
    return truncateLSB(bits << 1);
endfunction

function anytype dontCareValue() provisos(Bits#(anytype, tSz));
    return ?;
endfunction

function anytype unwrapMaybe(Maybe#(anytype) maybe) provisos(Bits#(anytype, tSz));
    return fromMaybe(?, maybe);
endfunction

function anytype unwrapMaybeWithDefault(
    Maybe#(anytype) maybe, anytype defaultVal
) provisos(Bits#(anytype, nSz));
    return fromMaybe(defaultVal, maybe);
endfunction

function anytype1 getTupleFirst(Tuple2#(anytype1, anytype2) tupleVal);
    return tpl_1(tupleVal);
endfunction

function anytype2 getTupleSecond(Tuple2#(anytype1, anytype2) tupleVal);
    return tpl_2(tupleVal);
endfunction

function anytype3 getTupleThird(Tuple3#(anytype1, anytype2, anytype3) tupleVal);
    return tpl_3(tupleVal);
endfunction

function anytype4 getTupleFourth(Tuple4#(anytype1, anytype2, anytype3, anytype4) tupleVal);
    return tpl_4(tupleVal);
endfunction

function anytype5 getTupleFifth(Tuple5#(anytype1, anytype2, anytype3, anytype4, anytype5) tupleVal);
    return tpl_5(tupleVal);
endfunction

function anytype6 getTupleSixth(Tuple6#(anytype1, anytype2, anytype3, anytype4, anytype5, anytype6) tupleVal);
    return tpl_6(tupleVal);
endfunction

function anytype identityFunc(anytype inputVal);
    return inputVal;
endfunction

function Action immAssert(Bool condition, String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        // let pos = printPosition(getEvalPosition(condition));
        if (!condition) begin
            $display(
                "ImmAssert failed in %m @time=%0t: %s-- %s: ",
                $time, pos, assertName, assertFmtMsg
            );
            $finish(1);
        end
    endaction
endfunction

function Action immFail(String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        // let pos = printPosition(getEvalPosition(condition));
        $display(
            "ImmAssert failed in %m @time=%0t: %s-- %s: ",
            $time, pos, assertName, assertFmtMsg
        );
        $finish(1);
    endaction
endfunction

// FlagsType related

typedef struct {
    Bit#(SizeOf#(enumType)) flags;
} FlagsType#(type enumType) deriving(Bits, Bitwise);

instance FShow#(FlagsType#(enumType)) provisos(
    Bits#(enumType, tSz),
    FShow#(enumType)
);
    function Fmt fshow(FlagsType#(enumType) inputVal);
        Bit#(tSz) enumBits = pack(inputVal);

        Fmt resultFmt = $format("FlagsType { flags: ", pack(inputVal), " = ");
        for (Integer idx = 0; idx < valueOf(tSz); idx = idx + 1) begin
            Bool bitValid = unpack(enumBits[idx]);
            enumType enumVal = unpack(1 << idx);
            if (bitValid) begin
                resultFmt = resultFmt + $format(fshow(enumVal), " | ");
            end
        end

        if (isZero(enumBits)) begin
            enumType enumVal = unpack(0);
            resultFmt = resultFmt + $format(fshow(enumVal), " }");
        end
        else begin
            resultFmt = resultFmt + $format("}");
        end
        return resultFmt;
    endfunction
endinstance

typeclass Flags#(type enumType);
    function Bool isOneHotOrZero(enumType inputVal);
endtypeclass

function FlagsType#(enumType) toFlag(enumType inputVal) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    let checkOneHotOrZero = isOneHotOrZero(inputVal);
    // TODO: check inputVal is onehot or zero
    // immAssert(
    //     1 >= numOnes,
    //     "numOnes assertion @ convert2Flag",
    //     $format(
    //         "inputVal=", fshow(inputVal),
    //         " should be one-hot but its value=%0d", pack(inputValue)
    //     )
    // );
    return unpack(pack(inputVal));
endfunction

// All Count interface methods of mkCountCF are CF
module mkCountCF#(anytype resetVal)(Count#(anytype)) provisos(
    Arith#(anytype), ModArith#(anytype), Bits#(anytype, tSz)
);
    Reg#(anytype)     cntReg <- mkReg(resetVal);
    Reg#(anytype) incrReg[2] <- mkCReg(2, 0);
    Reg#(anytype) decrReg[2] <- mkCReg(2, 0);

    // Reg#(Maybe#(anytype)) updateReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Maybe#(anytype)) writeReg[2] <- mkCReg(2, tagged Invalid);

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        if (writeReg[1] matches tagged Valid .writeVal) begin
            cntReg <= writeVal;
        end
        else begin
            cntReg <= cntReg + incrReg[1] - decrReg[1];
        end

        incrReg[1]  <= 0;
        decrReg[1]  <= 0;
        writeReg[1] <= tagged Invalid;
        // updateReg[1] <= tagged Invalid;
    endrule

    method Action incr(anytype incrVal);
        incrReg[0] <= incrVal;
    endmethod
    method Action decr(anytype decrVal);
        decrReg[0] <= decrVal;
    endmethod
    method Action update(anytype updateVal);
        error("update is not defined for mkCountCF");
        // updateReg[0] <= updateVal;
    endmethod
    method Action _write(anytype writeVal);
        writeReg[0] <= tagged Valid writeVal;
    endmethod
    method anytype _read = cntReg;
endmodule
