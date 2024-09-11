import FIFOF :: *;
import PAClib :: *;

typedef 2 TWO;
typedef 4 FOUR;

function Bool isZero(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = unpack(|bits);
    return !ret;
endfunction

// TODO: consider using fold
function Bool isZeroR(Bit#(nSz) bits) provisos(
    NumAlias#(TDiv#(nSz, 2), halfSz)
);
    if (valueOf(halfSz) > 1) begin
        Tuple2#(Bit#(TSub#(nSz, halfSz)), Bit#(halfSz)) pair = split(bits);
        let { left, right } = pair;
        return isZeroR(left) && isZeroR(right);
    end
    else begin
        return isZero(bits);
    end
endfunction

function Bool isZeroByteEn(Bit#(nSz) byteEn); // provisos(Add#(1, anysize, nSz));
    return isZero({ msb(byteEn), lsb(byteEn) });
endfunction

function Bool isLessOrEqOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = isZero(bits >> 1);
    // Bool ret = isZero(bits >> 1) && unpack(bits[0]);
    return ret;
endfunction

function Bool isLessOrEqOneR(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    Bool ret = isZeroR(bits >> 1);
    return ret;
endfunction

function Bool isOne(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return isLessOrEqOne(bits) && unpack(lsb(bits));
endfunction

function Bool isOneR(Bit#(nSz) bits); // provisos(Add#(1, anysize, nSz));
    return isLessOrEqOneR(bits) && unpack(lsb(bits));
endfunction

function Bool isTwo(Bit#(nSz) bits) provisos(Add#(2, anysize, nSz));
    return isZero(bits >> 2) && unpack(bits[1]) && !unpack(lsb(bits));
endfunction

function Bool isTwoR(Bit#(nSz) bits) provisos(Add#(2, anysize, nSz));
    return isZero(bits >> 2) && unpack(bits[1]) && !unpack(lsb(bits));
endfunction


function Bool isAllOnesR(Bit#(nSz) bits) provisos(
    NumAlias#(TDiv#(nSz, 2), halfSz)
);
    if (valueOf(halfSz) > 1) begin
        Tuple2#(Bit#(TSub#(nSz, halfSz)), Bit#(halfSz)) pair = split(bits);
        let { left, right } = pair;
        return isAllOnesR(left) && isAllOnesR(right);
    end
    else begin
        Bool ret = unpack(&bits);
        return ret;
    end
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
            $error(
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
        $error(
            "ImmAssert failed in %m @time=%0t: %s-- %s: ",
            $time, pos, assertName, assertFmtMsg
        );
        $finish(1);
    endaction
endfunction

typedef enum {
    AddressAlignAssertionMask4KB = 'hFFF,
    AddressAlignAssertionMask2MB = 'h1FFFFF
} AddressAlignAssertionMask deriving (Bits, Eq);

function Action immAssertAddressAlign(tAddr addr, AddressAlignAssertionMask alignMask, String name) provisos (
    Bits#(tAddr, szAddr),
    Bits#(AddressAlignAssertionMask, szMask),
    Add#(anySize, szMask, szAddr)
);
    action
        tAddr maskedAddr = unpack(zeroExtend(pack(alignMask)) & pack(addr));
        immAssert(
            pack(maskedAddr) == 0,
            "address not aligned @ immAssertAddressAlign",
            $format("name=%s, addr=%x, maskedLowerBIts=%x", name, addr, maskedAddr)
        );
    endaction
endfunction

// PipeOut related

function PipeOut#(anytype) toPipeOut(FIFOF#(anytype) queue);
    return f_FIFOF_to_PipeOut(queue);
endfunction

// FlagsType related

typedef struct {
    Bit#(SizeOf#(enumType)) flags;
} FlagsType#(type enumType) deriving(Bits, Bitwise, Eq);

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

function FlagsType#(enumType) enum2Flag(enumType inputVal) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    // TODO: check inputVal is onehot or zero
    // immAssert(
    //     isOneHotOrZero(inputVal),
    //     "numOnes assertion @ convert2Flag",
    //     $format(
    //         "inputVal=", fshow(inputVal),
    //         " should be one-hot but its value=%0d", pack(inputValue)
    //     )
    // );
    return unpack(pack(inputVal));
endfunction

// Check flags1 contains flags2 or not
function Bool containFlags(FlagsType#(enumType) flags1, FlagsType#(enumType) flags2) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    return (flags1 & flags2) == flags2;
    // Bit#(tSz) bitWiseResult = pack((flags1 & flags2) ^ flags2);
    // return isZero(bitWiseResult);
endfunction

function Bool containEnum(FlagsType#(enumType) flags, enumType enumVal) provisos(
    Bits#(enumType, tSz),
    Flags#(enumType)
);
    return !isZero(pack(flags & enum2Flag(enumVal)));
endfunction

// _read SB (incr CF decr) SB _write
interface CountCF#(type anytype);
    method Action incrOne();
    method Action decrOne();
    method Action _write (anytype write_val);
    method anytype _read();
endinterface

module mkCountCF#(anytype resetVal)(CountCF#(anytype)) provisos(
    Arith#(anytype), Bits#(anytype, tSz)
);
    Reg#(anytype) cntReg <- mkReg(resetVal);
    FIFOF#(Bool)   incrQ <- mkFIFOF;
    FIFOF#(Bool)   decrQ <- mkFIFOF;

    Reg#(Maybe#(anytype)) writeReg[2] <- mkCReg(2, tagged Invalid);
    Reg#(Bool) incrReg[2] <- mkCReg(2, False);
    Reg#(Bool) decrReg[2] <- mkCReg(2, False);

    (* no_implicit_conditions, fire_when_enabled *)
    rule write if (writeReg[1] matches tagged Valid .writeVal);
        cntReg <= writeVal;
        incrQ.clear;
        decrQ.clear;
        writeReg[1] <= tagged Invalid;
        incrReg[1]  <= False;
        decrReg[1]  <= False;
    endrule

    (* fire_when_enabled *)
    rule increment if (!isValid(writeReg[1]));
        incrReg[0] <= True;
        incrQ.deq;
    endrule

    (* fire_when_enabled *)
    rule decrement if (!isValid(writeReg[1]));
        decrReg[0] <= True;
        decrQ.deq;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule incrAndDecr if (!isValid(writeReg[1]));
        if (incrReg[1] && !decrReg[1]) begin
            cntReg <= cntReg + 1;
        end
        else if (!incrReg[1] && decrReg[1]) begin
            cntReg <= cntReg - 1;
        end

        incrReg[1] <= False;
        decrReg[1] <= False;
    endrule

    method Action incrOne();
        incrQ.enq(True);
    endmethod
    method Action decrOne();
        decrQ.enq(True);
    endmethod
    method Action _write(anytype writeVal);
        writeReg[0] <= tagged Valid writeVal;
    endmethod
    method anytype _read() = cntReg;
endmodule
