import Vector :: *;
import UserLogicSettings :: *;
import UserLogicTypes :: *;
import DataTypes :: *;
import Headers :: *;
import FIFOF :: *;
import Arbitration :: *;
import PAClib :: *;
import PrimUtils :: *;
import ClientServer :: *;
import GetPut :: *;
import ConfigReg :: * ;
import Randomizable :: *;
import PrimUtils :: *;
import RdmaUtils :: *;


function Bool isRingbufNotEmpty(RingbufPointer#(sz_rbp) head, RingbufPointer#(sz_rbp) tail);
    return !(head == tail);
endfunction

function Bool isRingbufNotFull(RingbufPointer#(sz_rbp) head, RingbufPointer#(sz_rbp) tail);
    return !((head.idx == tail.idx) && (head.guard != tail.guard));
endfunction

function Tuple2#(PageNumber4k, PageOffset4k) getPageNumberAndOffset4k(ADDR addr);
    return unpack(pack(addr));
endfunction

typedef struct {
    Bool guard;
    UInt#(w) idx;
} RingbufPointer#(numeric type w) deriving(Bits, Eq);

instance Arith#(RingbufPointer#(w)) provisos(Alias#(RingbufPointer#(w), data_t), Bits#(data_t, TAdd#(w, 1)));
    function data_t \+ (data_t x, data_t y);
        UInt#(TAdd#(w,1)) tx = unpack(pack(x));
        UInt#(TAdd#(w,1)) ty = unpack(pack(y));
        return unpack(pack(tx + ty));
    endfunction

    function data_t \- (data_t x, data_t y);
        UInt#(TAdd#(w,1)) tx = unpack(pack(x));
        UInt#(TAdd#(w,1)) ty = unpack(pack(y));
        return unpack(pack(tx - ty));
    endfunction

    function data_t \* (data_t x, data_t y);
        return error ("The operator " + quote("*") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t \/ (data_t x, data_t y);
        return error ("The operator " + quote("/") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t \% (data_t x, data_t y);
        return error ("The operator " + quote("%") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

    function data_t negate (data_t x);
        return error ("The operator " + quote("negate") +
                      " is not defined for " + quote("RingbufPointer") + ".");
    endfunction

endinstance

instance Literal#(RingbufPointer#(w));

   function fromInteger(n) ;
        return RingbufPointer{ guard: False, idx: fromInteger(n) } ;
   endfunction
   function inLiteralRange(a, i);
        UInt#(w) idxPart = ?;
        return inLiteralRange(idxPart, i);
   endfunction
endinstance

typedef RingbufPointer#(USER_LOGIC_RING_BUF_DEEP_WIDTH) Fix4kBRingBufPointer;


interface H2CRingBufFifoCntrlIfc#(type t_elem);
    method Action fillBuf(t_elem elem);
    method Bool notEmpty;
endinterface

interface H2CRingBuf#(type t_elem);
    interface PipeOut#(t_elem) pipeout;
    interface H2CRingBufFifoCntrlIfc#(t_elem) cntrl;
endinterface

module mkH2CRingBuf(Integer buf_depth, H2CRingBuf#(t_elem) ifc) provisos (Bits#(t_elem, sz_elem));
    FIFOF#(t_elem) bufQ <- mkSizedFIFOF(buf_depth);

    interface pipeout = toPipeOut(bufQ);

    interface H2CRingBufFifoCntrlIfc cntrl;
        method Action fillBuf(t_elem elem);
            bufQ.enq(elem);
        endmethod
        method Bool notEmpty = bufQ.notEmpty;
    endinterface
endmodule

interface C2HRingBufFifoIfc#(type t_elem);
    method Action enq(t_elem elem);
    method Bool notFull;
endinterface

interface C2HRingBuf#(type t_elem);
    interface C2HRingBufFifoIfc#(t_elem) fifo;
    interface PipeOut#(t_elem) cntrl;
endinterface

module mkC2HRingBuf(Integer buf_depth, C2HRingBuf#(t_elem) ifc) provisos (Bits#(t_elem, sz_elem));
    FIFOF#(t_elem) bufQ <- mkSizedFIFOF(buf_depth);

    interface C2HRingBufFifoIfc fifo;
        method Action enq(t_elem elem);
             bufQ.enq(elem);
        endmethod
        method Bool notFull = bufQ.notFull;
    endinterface

    interface cntrl = toPipeOut(bufQ);
endmodule

typedef UserLogicDmaReadClt RingbufDmaH2cClt;
typedef UserLogicDmaWriteClt RingbufDmaC2hClt;


interface RingbufH2cMetadata;
    interface Reg#(ADDR) addr;
    interface Reg#(Fix4kBRingBufPointer) head;
    interface Reg#(Fix4kBRingBufPointer) tail;
    interface Reg#(Fix4kBRingBufPointer) tailShadow;
endinterface

interface RingbufH2cController;
    interface RingbufH2cMetadata metadata;
    interface RingbufDmaH2cClt dmaClt;
endinterface

module mkRingbufH2cController(RingbufNumber qIdx, H2CRingBufFifoCntrlIfc#(t_elem) fifoCntrl, RingbufH2cController ifc)
    provisos(
        Bits#(t_elem, sz_elem),
        Bits#(RingbufRawDescriptor, sz_elem),
        FShow#(t_elem)
    );

    Reg#(ADDR) baseAddrReg <- mkReg(0);
    Reg#(Fix4kBRingBufPointer) headReg[2] <- mkCReg(2, unpack(0));
    Reg#(Fix4kBRingBufPointer) tailReg[2] <- mkCReg(2, unpack(0));
    Reg#(Fix4kBRingBufPointer) tailShadowReg <- mkConfigReg(unpack(0));
    FIFOF#(UserLogicDmaH2cReq) dmaReqQ <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cResp) dmaRespQ <- mkFIFOF;

    Reg#(Bool) ruleState <- mkReg(False);
    Reg#(RingbufReadBlockInnerOffset) tailPosInReadBlockReg <- mkReg(0);
    Reg#(DataStreamEn) dmaRespBeatBufReg <- mkReg(unpack(0));
    FIFOF#(Tuple2#(RingbufRawDescriptor, Bool)) splitedDescQ <- mkFIFOF;
    
    rule sendDmaReq if (ruleState == False);

        // generate a temp constant var as mask, use it to align pointer.
        Fix4kBRingBufPointer ringbufReadBlockInnerOffsetMask = 0;
        ringbufReadBlockInnerOffsetMask.idx = ~((1 << valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK))) - 1); 

        if (isRingbufNotEmpty(headReg[0], tailShadowReg) && !fifoCntrl.notEmpty) begin
            let {curReadBlockStartAddrPgn, _} = getPageNumberAndOffset4k(baseAddrReg);

            PageOffset4k curReadBlockStartAddrOff = zeroExtend(
                tailShadowReg.idx >> valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)) 
            ) << valueOf(RINGBUF_READ_BLOCK_BYTE_WIDTH);
            ADDR curReadBlockStartAddr = unpack({pack(curReadBlockStartAddrPgn), pack(curReadBlockStartAddrOff)});

            let readBlockAlignedTailShadow = tailShadowReg + fromInteger(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK));
            readBlockAlignedTailShadow.idx = readBlockAlignedTailShadow.idx & ringbufReadBlockInnerOffsetMask.idx;

            let availableEntryCnt = headReg[0] - tailShadowReg;
            let avaliableSlotInReadBlock = fromInteger(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK)) - pack(tailShadowReg.idx)[valueOf(TLog#(RINGBUF_DESC_ENTRY_PER_READ_BLOCK))-1:0];
            
            Fix4kBRingBufPointer newTailShadow;
            if (pack(availableEntryCnt) > avaliableSlotInReadBlock) begin
                newTailShadow = readBlockAlignedTailShadow;
            end 
            else begin
                newTailShadow = headReg[0];
            end

            dmaReqQ.enq(UserLogicDmaH2cReq{
                    addr: curReadBlockStartAddr,
                    len: fromInteger(valueOf(RINGBUF_BLOCK_READ_LEN))
            });
            // $display("h2c ringbuf send new dma request");
            tailPosInReadBlockReg <= truncate(pack(tailReg[0]));

            tailShadowReg <= newTailShadow;
            ruleState <= True;
        end
    endrule

    rule dmaRespBitWidthSplit;
        let fullResp = dmaRespBeatBufReg;
        if (lsb(fullResp.byteEn) == 0) begin
            dmaRespQ.deq;
            fullResp = dmaRespQ.first.dataStream;
        end

        RingbufRawDescriptor desc = truncate(fullResp.data);

        fullResp.data = fullResp.data >> valueOf(USER_LOGIC_DESCRIPTOR_BIT_WIDTH);
        fullResp.byteEn = fullResp.byteEn >> valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH);
        let isLast = fullResp.isLast && (lsb(fullResp.byteEn) == 0);

        splitedDescQ.enq(tuple2(desc, isLast));
        dmaRespBeatBufReg <= fullResp;
    endrule

    rule recvDmaResp if (ruleState == True);
        let {desc, isLast} = splitedDescQ.first;
        splitedDescQ.deq;

        if (tailPosInReadBlockReg > 0) begin
            // skip already consumed descriptors in previous block read.
            tailPosInReadBlockReg <= tailPosInReadBlockReg - 1;
            // $display("skip already handled...tailPosInReadBlockReg=", tailPosInReadBlockReg);
        end 
        else begin
            let newTail = tailReg[0];
            if (tailReg[0] != tailShadowReg) begin
                // the end of read block may contain invalid descriptors, don't handle descriptors beyond tailShadowReg
                t_elem t = unpack(pack(desc));
                // $display("Ringbuf H2c enqueue descriptor, qIdx=", fshow(qIdx), fshow(t));
                fifoCntrl.fillBuf(t);
                newTail = tailReg[0] + 1;
                tailReg[0] <= newTail;
                // $display("tail incr...old tailReg=%h, new=%x", tailReg[0], newTail);
            end 
            else begin
                // $display("skip invalid...tailReg=%h", tailReg[0]);
            end

            if (isLast) begin
                // $display("current read block finished.");
                ruleState <= False;
                immAssert(
                    newTail == tailShadowReg,
                    "shadowTail assertion @ mkRingbufH2cMetadata",
                    $format(
                        "newTail=%h should == shadowTail=%h, ",
                        newTail, tailShadowReg
                    )
                );
            end
        end
    endrule

    interface RingbufH2cMetadata metadata;
        interface addr = baseAddrReg;
        interface head = headReg[1];
        interface tail = tailReg[1];
        interface tailShadow = tailShadowReg;
    endinterface
    interface dmaClt = toGPClient(dmaReqQ, dmaRespQ);
endmodule


interface RingbufC2hMetadata;
    interface Reg#(ADDR) addr;
    interface Reg#(Fix4kBRingBufPointer) head;
    interface Reg#(Fix4kBRingBufPointer) tail;
    interface Reg#(Fix4kBRingBufPointer) headShadow;
endinterface

interface RingbufC2hController;
    interface RingbufC2hMetadata metadata;
    interface RingbufDmaC2hClt dmaClt;
endinterface


// TODO: For C2H, doesn't support batch descriptor writeback now. 
module mkRingbufC2hController(RingbufNumber qIdx, PipeOut#(t_elem) fifoCntrl, RingbufC2hController ifc)
    provisos(
        Bits#(t_elem, sz_elem),
        Bits#(RingbufRawDescriptor, sz_elem)
    );

    Reg#(ADDR) baseAddrReg <- mkReg(0);
    Reg#(Fix4kBRingBufPointer) headReg[2] <- mkCReg(2, unpack(0));
    Reg#(Fix4kBRingBufPointer) tailReg[2] <- mkCReg(2, unpack(0));
    Reg#(Fix4kBRingBufPointer) headShadowReg <- mkConfigReg(unpack(0));
    FIFOF#(UserLogicDmaC2hReq) dmaReqQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hResp) dmaRespQ <- mkFIFOF;

    Reg#(RingbufReadBlockInnerOffset) headPosInReadBlockReg <- mkReg(0);

    rule sendDmaReq;

        if (isRingbufNotFull(headShadowReg, tailReg[0]) && fifoCntrl.notEmpty) begin

            let {curWriteBlockStartAddrPgn, _} = getPageNumberAndOffset4k(baseAddrReg);

            PageOffset4k curWriteBlockStartAddrOff = zeroExtend(
                headShadowReg.idx
            ) << valueOf(TLog#(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH));

            ADDR curWriteStartAddr = unpack({pack(curWriteBlockStartAddrPgn), pack(curWriteBlockStartAddrOff)});

            DataStream ds;
            ds.isLast = True;
            ds.isFirst = True;
            ds.byteNum = fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH));
            ds.data = unpack(zeroExtend(pack(fifoCntrl.first)));
            fifoCntrl.deq;

            dmaReqQ.enq(UserLogicDmaC2hReq{
                    addr: curWriteStartAddr,
                    len: fromInteger(valueOf(USER_LOGIC_DESCRIPTOR_BYTE_WIDTH)),
                    dataStream: dataStream2DataStreamEnRightAlign(ds)
            });

            headShadowReg <= headShadowReg + 1;
        end
    endrule

    rule recvDmaResp;
        dmaRespQ.deq;
        let resp = dmaRespQ.first;
        // $display("recvDmaResp @ Q=%d -- head = %x, tail = %x, head_shadow = %x", qIdx, headReg[0], tailReg[0], headShadowReg);
        let newHead = headReg[0] + 1;
        headReg[0] <= newHead;
        // $display("head incr...old headReg=%h, new=%x", headReg[0], newHead);
    endrule

    interface RingbufC2hMetadata metadata;
        interface addr = baseAddrReg;
        interface head = headReg[1];
        interface tail = tailReg[1];
        interface headShadow = headShadowReg;
    endinterface
    interface dmaClt = toGPClient(dmaReqQ, dmaRespQ);
endmodule




interface RingbufPool#(numeric type h2cCount, numeric type c2hCount, type t_elem);
    interface Vector#(h2cCount, PipeOut#(t_elem)) h2cRings;
    interface Vector#(h2cCount, RingbufH2cMetadata) h2cMetas;
    interface Vector#(c2hCount, C2HRingBufFifoIfc#(t_elem)) c2hRings;
    interface Vector#(c2hCount, RingbufC2hMetadata) c2hMetas;
    interface RingbufDmaH2cClt dmaAccessH2cClt;
    interface RingbufDmaC2hClt dmaAccessC2hClt;
endinterface

module mkRingbufPool(
    RingbufPool#(h2cCount, c2hCount, t_elem) ifc
) provisos (
    Add#(1, anysize1, h2cCount),
    Add#(TLog#(h2cCount), 1, TLog#(TAdd#(1, h2cCount))),
    Add#(1, anysize2, c2hCount),
    Add#(TLog#(c2hCount), 1, TLog#(TAdd#(1, c2hCount))),
    Bits#(t_elem, sz_elem),
    Bits#(RingbufRawDescriptor, sz_elem),
    FShow#(t_elem)
);
    
    Vector#(h2cCount, RingbufDmaH2cClt) dmaAccessH2cCltVec = newVector;
    Vector#(h2cCount, PipeOut#(t_elem)) h2cPipeouts = newVector;
    Vector#(h2cCount, RingbufH2cMetadata) h2cMetaData = newVector;
    for (Integer i=0; i< valueOf(h2cCount); i=i+1) begin
        H2CRingBuf#(t_elem) t <- mkH2CRingBuf(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK));
        h2cPipeouts[i] = t.pipeout;
        RingbufH2cController controller <- mkRingbufH2cController(fromInteger(i), t.cntrl);
        h2cMetaData[i] = controller.metadata;
        dmaAccessH2cCltVec[i] = controller.dmaClt;
    end
 
    Vector#(c2hCount, RingbufDmaC2hClt) dmaAccessC2hCltVec = newVector;
    Vector#(c2hCount, C2HRingBufFifoIfc#(t_elem)) c2hFifos = newVector;
    Vector#(c2hCount, RingbufC2hMetadata) c2hMetaData = newVector;
    for (Integer i=0; i< valueOf(c2hCount); i=i+1) begin
        C2HRingBuf#(t_elem) t <- mkC2HRingBuf(valueOf(RINGBUF_DESC_ENTRY_PER_READ_BLOCK));
        c2hFifos[i] = t.fifo;
        RingbufC2hController controller <- mkRingbufC2hController(fromInteger(i), t.cntrl);
        c2hMetaData[i] = controller.metadata;
        dmaAccessC2hCltVec[i] = controller.dmaClt;
    end



    function Bool alwaysTrue(anytype resp);
        return True;
    endfunction

    function Bool isRingbufDmaRespFinished(UserLogicDmaH2cResp resp);
        return resp.dataStream.isLast;
    endfunction
    

    let arbitratedH2cClient <- mkClientArbiter(
        "Ringbuf arbitratedH2cClient",
        False,
        2,
        dmaAccessH2cCltVec,
        alwaysTrue,
        isRingbufDmaRespFinished
    );

    let arbitratedC2hClient <- mkClientArbiter(
        "Ringbubf arbitratedC2hClient",
        False,
        2,
        dmaAccessC2hCltVec,
        alwaysTrue,
        alwaysTrue
    );

    interface h2cRings = h2cPipeouts;
    interface h2cMetas = h2cMetaData;
    interface c2hRings = c2hFifos;
    interface c2hMetas = c2hMetaData;
    interface dmaAccessH2cClt = arbitratedH2cClient;
    interface dmaAccessC2hClt = arbitratedC2hClient;
endmodule




interface RingbufDescriptorReadProxy#(numeric type n_desc);
    interface Put#(RingbufRawDescriptor) ringbufConnector;
    method ActionValue#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) getWideDesc();
endinterface

interface RingbufDescriptorWriteProxy#(numeric type n_desc);
    interface Get#(RingbufRawDescriptor) ringbufConnector;
    method Action setWideDesc(Vector#(n_desc, RingbufRawDescriptor) descs, DescriptorSegmentIndex extraDescCount);
    method Bool canSetDesc();
endinterface

module mkRingbufDescriptorReadProxy(RingbufDescriptorReadProxy#(n_desc));
    FIFOF#(RingbufRawDescriptor) ringbufQ <- mkFIFOF;


    Vector#(n_desc, Reg#(RingbufRawDescriptor)) segBuf <- replicateM(mkRegU);

    Reg#(Bool) isFillingReqSegmentsReg <- mkReg(True); 
    Reg#(Bool) isFirstReqSegmentsReg <- mkReg(True); 
    Reg#(DescriptorSegmentIndex) totalSegCntReg <- mkRegU;
    Reg#(DescriptorSegmentIndex) curSegCntReg <- mkReg(0);

    rule fillAllReqSegments if (isFillingReqSegmentsReg);
        let rawDesc = ringbufQ.first;
        ringbufQ.deq;
        segBuf[0] <= rawDesc;
        DescriptorSegmentIndex totalSegCnt = totalSegCntReg;
        DescriptorSegmentIndex curSegCnt = curSegCntReg;
        if (isFirstReqSegmentsReg) begin
            CmdQueueDescCommonHead head = unpack(truncate(rawDesc));
            totalSegCnt = unpack(head.extraSegmentCnt);
            curSegCnt = 0;
        end
        let hasMoreSegs = totalSegCnt != curSegCnt;
        if (!hasMoreSegs) begin
            isFirstReqSegmentsReg <= True;
            isFillingReqSegmentsReg <= False;
        end 
        else begin
            isFirstReqSegmentsReg <= False;
            isFillingReqSegmentsReg <= True;
        end
        for (Integer i = 0; i < valueOf(n_desc) - 1; i=i+1) begin
            segBuf [i+1] <= segBuf[i];
        end

        curSegCnt = curSegCnt + 1;
        curSegCntReg <= curSegCnt; 
        totalSegCntReg <= totalSegCnt;
    endrule

    method ActionValue#(Tuple2#(Vector#(n_desc, RingbufRawDescriptor), DescriptorSegmentIndex)) getWideDesc() if (!isFillingReqSegmentsReg);
        isFillingReqSegmentsReg <= True;
        let headDescIdx = totalSegCntReg;
        return tuple2(readVReg(segBuf), headDescIdx);
    endmethod


    interface ringbufConnector = toPut(ringbufQ);
endmodule



module mkRingbufDescriptorWriteProxy(RingbufDescriptorWriteProxy#(n_desc));
    FIFOF#(RingbufRawDescriptor) ringbufQ <- mkFIFOF;

    Vector#(n_desc, Reg#(RingbufRawDescriptor)) segBuf <- replicateM(mkRegU);

    Reg#(Bool) isSendingDescReg <- mkReg(False); 
    Reg#(DescriptorSegmentIndex) segCntReg <- mkRegU;
    
    rule sendRespDesc if (isSendingDescReg);
        ringbufQ.enq(segBuf[0]);
        for (Integer i = 0; i < valueOf(n_desc) - 1; i=i+1) begin
            segBuf [i] <= segBuf[i+1];
        end
        if (segCntReg == 0) begin
            isSendingDescReg <= False;
        end
        segCntReg <= segCntReg - 1;
    endrule

    method Action setWideDesc(Vector#(n_desc, RingbufRawDescriptor) descs, DescriptorSegmentIndex extraDescCount) if (!isSendingDescReg);
        isSendingDescReg <= True;
        segCntReg <= extraDescCount;
        writeVReg(segBuf, descs);
    endmethod

    method Bool canSetDesc = !isSendingDescReg;

    interface ringbufConnector = toGet(ringbufQ);
endmodule