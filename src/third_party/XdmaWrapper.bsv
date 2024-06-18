import FIFOF :: *;
import SpecialFIFOs :: *;
import ClientServer :: * ;
import GetPut :: *;
import Clocks :: * ;
import Vector :: *;
import BRAM :: *;

import Settings :: *;

import UserLogicSettings :: *;
import UserLogicTypes :: *;
import RdmaUtils :: *;

import DataTypes :: *;
import SemiFifo :: *;
import BusConversion :: *;
import AxiStreamTypes :: *;
import Axi4LiteTypes :: *;
import Headers :: *;
import Gearbox :: *;
import AlignedFIFOs :: * ;

import PrimUtils :: *;
import Connectable :: * ;
import StmtFSM::*;
import Randomizable :: * ;
import MockHost :: *;
import Ports :: *;


typedef Bit#(64) XdmaDescBypAddr;
typedef Bit#(28) XdmaDescBypLength;
typedef struct {
    Bool eop;
    Bit#(2) _rsv;
    Bool completed;
    Bool stop;
} XdmaDescBypCtl deriving(Bits);


typedef struct {
    Bit#(1) _rsv;
    Bool running;
    Bool irqPending;
    Bool packetDone;
    Bool descDone;
    Bool descStop;
    Bool descCplt;
    Bool busy;
} XdmaChannelStatus deriving(Bits);

(* always_ready, always_enabled *)
interface XdmaDescriptorBypass;
    (* prefix = "" *)     method Action ready((* port = "ready" *) Bool rdy);
    (* result = "load" *) method Bool   load;
    (* result = "src_addr" *) method XdmaDescBypAddr  srcAddr;
    (* result = "dst_addr" *) method XdmaDescBypAddr  dstAddr;
    (* result = "len" *) method XdmaDescBypLength  len;
    (* result = "ctl" *) method XdmaDescBypCtl  ctl;
    (* prefix = "" *) method Action descDone((* port = "desc_done" *) Bool done) ;
endinterface

interface XdmaChannel#(numeric type dataSz, numeric type userSz);
    interface RawAxiStreamSlave#(dataSz, userSz) rawH2cAxiStream;
    interface RawAxiStreamMaster#(dataSz, userSz) rawC2hAxiStream;
    interface XdmaDescriptorBypass h2cDescByp;
    interface XdmaDescriptorBypass c2hDescByp;
endinterface

interface XdmaWrapper#(numeric type dataSz, numeric type userSz);
    interface UserLogicDmaReadWideSrv dmaReadSrv;
    interface UserLogicDmaWriteWideSrv dmaWriteSrv;
    interface XdmaChannel#(dataSz, userSz) xdmaChannel;
endinterface

(* synthesize *)
module mkXdmaWrapper(XdmaWrapper#(USER_LOGIC_XDMA_KEEP_WIDTH, USER_LOGIC_XDMA_TUSER_WIDTH));

    FIFOF#(AxiStream#(USER_LOGIC_XDMA_KEEP_WIDTH, USER_LOGIC_XDMA_TUSER_WIDTH)) xdmaH2cStFifo <- mkFIFOF();
    let rawH2cSt <- mkFifoInToRawAxiStreamSlave(convertFifoToFifoIn(xdmaH2cStFifo));

    FIFOF#(AxiStream#(USER_LOGIC_XDMA_KEEP_WIDTH, USER_LOGIC_XDMA_TUSER_WIDTH)) xdmaC2hStFifo <- mkFIFOF();
    let rawC2hSt <- mkPipeOutToRawAxiStreamMaster(toPipeOut(xdmaC2hStFifo));

    let dmaReadReqQ     <- mkFIFOF;
    let dmaReadRespQ    <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) dmaWriteReqQ <- mkFIFOF;
    let dmaWriteRespQ   <- mkFIFOF;

    FIFOF#(UserLogicDmaH2cReq) readReqProcessingQ   <- mkSizedFIFOF(12);
    FIFOF#(UserLogicDmaC2hWideReq) writeReqProcessingQ <- mkSizedFIFOF(12);

    Wire#(Bool) h2cDescBypRdyWire <- mkBypassWire;
    Reg#(Bool) h2cNextBeatIsFirst <- mkReg(True);

    Wire#(Bool) c2hDescBypRdyWire   <- mkBypassWire;
    Reg#(Bool) c2hNextBeatIsFirst   <- mkReg(True);
    Wire#(Bool) c2hDescBypDoneWire  <- mkBypassWire;
    
    Bool h2cDescHandshakeWillSuccess = h2cDescBypRdyWire && dmaReadReqQ.notEmpty && readReqProcessingQ.notFull;

    rule forwardH2cDesc;
        if (h2cDescHandshakeWillSuccess) begin
            dmaReadReqQ.deq;
            readReqProcessingQ.enq(dmaReadReqQ.first);
        end
    endrule

    rule forawrdH2cData;
        let newData = xdmaH2cStFifo.first;
        let currentProcessingReq = readReqProcessingQ.first;
        xdmaH2cStFifo.deq;
        dmaReadRespQ.enq(UserLogicDmaH2cWideResp{
            dataStream: DataStreamWideEn{
                data: unpack(pack(newData.tData)),
                byteEn: newData.tKeep,
                isFirst: h2cNextBeatIsFirst,
                isLast: newData.tLast
            }
        });
        if (newData.tLast) begin
            h2cNextBeatIsFirst <= True;
            readReqProcessingQ.deq;
        end 
        else begin
            h2cNextBeatIsFirst <= False;
        end
    endrule

    Bool c2hDescHandshakeWillSuccess = 
         c2hDescBypRdyWire && 
         dmaWriteReqQ.notEmpty &&
         dmaWriteReqQ.first.dataStream.isFirst && 
         writeReqProcessingQ.notFull && xdmaC2hStFifo.notFull && dmaWriteRespQ.notFull;  // make sure only handshake once.

    rule forwardC2hDescAndData;
        // Invariant: The descriptor count is always less than or equal to data segement count.
        // so only when data queue full it will block desc queue, but not vice versa
        // since the request from user logic combine metadata(descriptor) and data in the same channel, but
        // the xdma has two seperated channel for descriptor and data, we should split it.
        // in fact, the handshake for descriptor channel is done in the following `c2hDescByp` interface, it is done
        // automatically when we move (descriptor+data) into the data channel, controlled by 
        // `c2hDescHandshakeWillSuccess` signal. 
        // In other words, we must make sure that when c2hDescHandshakeWillSuccess is true, this rule must be also fired.

        // make sure we won't lost data on descriptor channel.(in fact, this should always be true when the implicity guard is true)
        if (c2hDescBypRdyWire == True) begin
            dmaWriteReqQ.deq;

            xdmaC2hStFifo.enq(
                AxiStream {
                    tData: unpack(pack(dmaWriteReqQ.first.dataStream.data)),
                    tKeep: dmaWriteReqQ.first.dataStream.byteEn,
                    tUser: ?,
                    tLast: dmaWriteReqQ.first.dataStream.isLast
                }
            );

            if (dmaWriteReqQ.first.dataStream.isFirst) begin
                writeReqProcessingQ.enq(dmaWriteReqQ.first);
            end
        end 
        else begin
            $error("This rule should not be fired when c2hDescBypRdyWire is False\n");
        end
    endrule


    interface dmaReadSrv = toGPServer(dmaReadReqQ, dmaReadRespQ);
    interface dmaWriteSrv = toGPServer(dmaWriteReqQ, dmaWriteRespQ);

    interface XdmaChannel xdmaChannel;

        interface rawH2cAxiStream = rawH2cSt;
        interface rawC2hAxiStream = rawC2hSt;

        interface XdmaDescriptorBypass h2cDescByp;

            method Action ready(Bool rdy);
                h2cDescBypRdyWire <= rdy;
            endmethod

            method Bool load;
                return h2cDescHandshakeWillSuccess;
            endmethod

            method XdmaDescBypAddr  srcAddr;
                return h2cDescHandshakeWillSuccess ? dmaReadReqQ.first.addr : ?;
            endmethod

            method XdmaDescBypAddr  dstAddr;
                return 0;
            endmethod

            method XdmaDescBypLength len;
                return h2cDescHandshakeWillSuccess ? extend(dmaReadReqQ.first.len) : ?;
            endmethod

            method XdmaDescBypCtl ctl;
                return XdmaDescBypCtl {
                    eop: True,
                    _rsv: 0,
                    completed: False,
                    stop: False
                };
            endmethod

            method Action descDone(Bool done);
            endmethod
        endinterface

        interface XdmaDescriptorBypass c2hDescByp;

            method Action ready(Bool rdy);
                c2hDescBypRdyWire <= rdy;
            endmethod

            method Bool load;
                return c2hDescHandshakeWillSuccess;
            endmethod

            method XdmaDescBypAddr  srcAddr;
                return 0;
            endmethod

            method XdmaDescBypAddr  dstAddr;
                return c2hDescHandshakeWillSuccess ? dmaWriteReqQ.first.addr : ?;
            endmethod

            method XdmaDescBypLength  len;
                return c2hDescHandshakeWillSuccess ? extend(dmaWriteReqQ.first.len) : ?;
            endmethod

            method XdmaDescBypCtl  ctl;
                return XdmaDescBypCtl {
                    eop: True,
                    _rsv: 0,
                    completed: False,
                    stop: False
                };
            endmethod

            method Action descDone(Bool done);
                c2hDescBypDoneWire <= done;
                if (!writeReqProcessingQ.notEmpty) begin
                    // $error("This rule should not be fired when writeReqProcessingQ is empty\n");
                end 
                else if (!dmaWriteRespQ.notFull) begin
                    // $error("This rule should not be fired when dmaWriteRespQ is full\n");
                end 
                else begin
                    writeReqProcessingQ.deq;
                    dmaWriteRespQ.enq(UserLogicDmaC2hResp{}); 
                end
            endmethod
        endinterface

    endinterface
endmodule


interface DmaReqMiddleLayerForBandwidthTest;
    interface UserLogicDmaReadWideSrv dmaReadSrv;
    interface UserLogicDmaWriteWideSrv dmaWriteSrv;
    interface UserLogicDmaReadWideClt dmaReadClt;
    interface UserLogicDmaWriteWideClt dmaWriteClt;
endinterface

typedef 8 BANDWIDTH_TEST_TRIGGER_MARK_ADDR_BIT_WIDTH;
typedef 'hAA BANDWIDTH_TEST_TRIGGER_ADDR_BIT_VALUE;
typedef Bit#(BANDWIDTH_TEST_TRIGGER_MARK_ADDR_BIT_WIDTH) BandwidthTriggerMark;

(* synthesize *)
module mkDmaReqMiddleLayerForBandwidthTest(DmaReqMiddleLayerForBandwidthTest);

    FIFOF#(UserLogicDmaH2cReq) dmaReadReqSrvQ     <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cWideResp) dmaReadRespSrvQ   <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) dmaWriteReqSrvQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hResp) dmaWriteRespSrvQ   <- mkFIFOF;

    FIFOF#(UserLogicDmaH2cReq) dmaReadReqCltQ     <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cWideResp) dmaReadRespCltQ    <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) dmaWriteReqCltQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hResp) dmaWriteRespCltQ   <- mkFIFOF;

    FIFOF#(UserLogicDmaH2cReq) dmaReadReqFakeQ     <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cWideResp) dmaReadRespFakeQ    <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) dmaWriteReqFakeQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hResp) dmaWriteRespFakeQ   <- mkFIFOF;



    Reg#(Byte) readGenCounter  <- mkRegU;
    Reg#(Byte) writeGenCounter <- mkRegU;

    FIFOF#(Bool) readReqKeepOrderQ  <- mkFIFOF;
    FIFOF#(Bool) writeReqKeepOrderQ <- mkFIFOF;

    Reg#(UserLogicDmaLen) fakeReadLengthReg <- mkRegU;
    Reg#(Byte) fakeReadDataReg <- mkRegU;
    Reg#(Bool) fakeReadisFirstBeatReg <- mkReg(True);

    Reg#(Byte) fakeWriteDataReg <- mkRegU;
    Reg#(Bool) fakeWriteCheckHasErrorReg <- mkReg(False);

    Bool is_FAKE = True;

    Reg#(Bool) startTimCounterReg[2] <- mkCReg(2, False);
    Reg#(Bit#(32)) timCounterReg <- mkReg(0);
    Reg#(Bit#(32)) timCounterSnapshotReg <- mkReg(0);
    Reg#(Bit#(32)) packetCounterReg <- mkReg(0);

    function DATA_WIDE fillDataStreamWithByte(Byte value);
        DATA_WIDE outData = ?;
        for (Integer idx = 0; idx < valueOf(DATA_BUS_BYTE_WIDTH); idx=idx+1) begin
            outData[(idx+1) * valueOf(BYTE_WIDTH) - 1 : idx * valueOf(BYTE_WIDTH)] = value;
        end
        return outData;
    endfunction

    rule runFreeCounter if (startTimCounterReg[1]);
        timCounterReg <= timCounterReg + 1;
    endrule

    rule genFakeReadData;
        let curLeftLen = fakeReadisFirstBeatReg ? dmaReadReqFakeQ.first.len : fakeReadLengthReg;
        Byte curData = fakeReadisFirstBeatReg ? truncate(dmaReadReqFakeQ.first.addr) : fakeReadDataReg;
        let data = fillDataStreamWithByte(curData);

        if (fakeReadisFirstBeatReg) begin
            $display("updateing read gen curData to curData=", fshow(curData));
        end

        if (fakeReadisFirstBeatReg) begin
            fakeReadLengthReg <= curLeftLen - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        end
        else begin
            fakeReadLengthReg <= fakeReadLengthReg - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        end

        let ds = ?;
        if (curLeftLen > fromInteger(valueOf(DATA_BUS_BYTE_WIDTH))) begin
            ds = DataStreamWideEn {
                isFirst: fakeReadisFirstBeatReg,
                isLast: False,
                data: data,
                byteEn: -1
            };
            fakeReadisFirstBeatReg <= False;
            fakeReadDataReg <= curData + 1;
        end
        else begin
            ds = DataStreamWideEn {
                isFirst: fakeReadisFirstBeatReg,
                isLast: True,
                data: data,
                byteEn: (1 << curLeftLen) - 1
            };
            dmaReadReqFakeQ.deq;
            fakeReadisFirstBeatReg <= True;
        end
        $display("time=%0t: ", $time, 
                 ", mkDmaReqMiddleLayerForBandwidthTest, send dma Read Resp=", fshow(ds),
                 ", req=", fshow(dmaReadReqFakeQ.first));

        dmaReadRespFakeQ.enq(UserLogicDmaH2cWideResp{dataStream:ds});
    endrule


    rule checkFakeWriteData;
        let req = dmaWriteReqFakeQ.first;
        let reqDs = req.dataStream;
        dmaWriteReqFakeQ.deq;
        
        Byte curData = reqDs.isFirst ? truncate(req.addr) : fakeWriteDataReg;
        if (reqDs.isFirst) begin
            $display("updateing write check curData to curData=", fshow(curData));
            startTimCounterReg[0] <= True;
        end
        fakeWriteDataReg <= curData + 1;

        if (truncate(reqDs.data) != curData || truncateLSB(reqDs.data) != curData) begin
            fakeWriteCheckHasErrorReg <= True;
            $display("Error: bandwidth test check error, expect ", fshow(curData), "got ", fshow(reqDs.data));
            $finish;
        end

        packetCounterReg <= packetCounterReg + 1;
        
        if (reqDs.isLast) begin
            dmaWriteRespFakeQ.enq(UserLogicDmaC2hResp{});
            
            timCounterSnapshotReg <= timCounterReg;

            Bit#(64) bw = zeroExtend(packetCounterReg);
            bw = bw * fromInteger(valueOf(DATA_BUS_WIDTH));
            bw = bw / (zeroExtend(timCounterReg) * 4);
            $display("time=%0t: ", $time, 
                 ", mkDmaReqMiddleLayerForBandwidthTest, time_pass = %d ns", timCounterReg * 4,
                 ", packet_cnt = %d", packetCounterReg+1,
                 ", bandwidth = %d Gbps", bw
                 );
        end

        $display("time=%0t: ", $time, 
                 ", mkDmaReqMiddleLayerForBandwidthTest, recv dma Write Req=", fshow(req));
    endrule

    rule forwardReadReq;
        let req = dmaReadReqSrvQ.first;
        dmaReadReqSrvQ.deq;
        PADDR phyAddr = truncate(req.addr);
        
        BandwidthTriggerMark triggerMark = truncateLSB(phyAddr);
        $display("req.addr=", fshow(req.addr), "phyAddr=", fshow(phyAddr), "triggerMark=", fshow(triggerMark));
        if (triggerMark == fromInteger(valueOf(BANDWIDTH_TEST_TRIGGER_ADDR_BIT_VALUE))) begin
            dmaReadReqFakeQ.enq(req);
            readReqKeepOrderQ.enq(is_FAKE);
        end
        else begin
            dmaReadReqCltQ.enq(req);
            readReqKeepOrderQ.enq(!is_FAKE);
        end
    endrule

    rule forwardReadResp;
        let isFake = readReqKeepOrderQ.first;
        if (isFake) begin
            let resp = dmaReadRespFakeQ.first;
            dmaReadRespFakeQ.deq;
            dmaReadRespSrvQ.enq(resp);
            if (resp.dataStream.isLast) begin
                readReqKeepOrderQ.deq;
            end
        end
        else begin
            let resp = dmaReadRespCltQ.first;
            dmaReadRespCltQ.deq;
            dmaReadRespSrvQ.enq(resp);
            if (resp.dataStream.isLast) begin
                readReqKeepOrderQ.deq;
            end
        end
    endrule

    rule forwardWriteReq;
        let req = dmaWriteReqSrvQ.first;
        dmaWriteReqSrvQ.deq;
        PADDR phyAddr = truncate(req.addr);
        BandwidthTriggerMark triggerMark = truncateLSB(phyAddr);
        $display("req.addr=", fshow(req.addr), "phyAddr=", fshow(phyAddr), "triggerMark=", fshow(triggerMark));
        if (triggerMark == fromInteger(valueOf(BANDWIDTH_TEST_TRIGGER_ADDR_BIT_VALUE))) begin
            dmaWriteReqFakeQ.enq(req);
            if (req.dataStream.isFirst) begin
                writeReqKeepOrderQ.enq(is_FAKE);
            end
        end
        else begin
            dmaWriteReqCltQ.enq(req);
            if (req.dataStream.isFirst) begin
                writeReqKeepOrderQ.enq(!is_FAKE);
            end
        end
    endrule

    rule forwardWriteResp;
        let isFake = writeReqKeepOrderQ.first;
        if (isFake) begin
            let resp = dmaWriteRespFakeQ.first;
            dmaWriteRespFakeQ.deq;
            dmaWriteRespSrvQ.enq(resp);
            writeReqKeepOrderQ.deq;
        end
        else begin
            let resp = dmaWriteRespCltQ.first;
            dmaWriteRespCltQ.deq;
            dmaWriteRespSrvQ.enq(resp);
            writeReqKeepOrderQ.deq;
        end
    endrule

    interface dmaReadSrv = toGPServer(dmaReadReqSrvQ, dmaReadRespSrvQ);
    interface dmaWriteSrv = toGPServer(dmaWriteReqSrvQ, dmaWriteRespSrvQ);

    interface dmaReadClt = toGPClient(dmaReadReqCltQ, dmaReadRespCltQ);
    interface dmaWriteClt = toGPClient(dmaWriteReqCltQ, dmaWriteRespCltQ);
endmodule




interface XdmaAxiLiteBridgeWrapper#(type t_csr_addr, type t_csr_data);
    interface RawAxi4LiteSlave#(SizeOf#(t_csr_addr), TDiv#(SizeOf#(t_csr_data),BYTE_WIDTH)) cntrlAxil;
    interface Client#(CsrReadRequest#(t_csr_addr), CsrReadResponse#(t_csr_data)) csrReadClt;
    interface Client#(CsrWriteRequest#(t_csr_addr, t_csr_data), CsrWriteResponse) csrWriteClt; 
endinterface 

module mkXdmaAxiLiteBridgeWrapper(Clock slowClock, Reset slowReset, XdmaAxiLiteBridgeWrapper#(t_csr_addr, t_csr_data) ifc) 
    provisos (
        Bits#(t_csr_addr, sz_csr_addr),
        Bits#(t_csr_data, sz_csr_data),
        Mul#(sz_csr_strb, BYTE_WIDTH, sz_csr_data),
        Div#(sz_csr_data, BYTE_WIDTH, sz_csr_strb),
        Div#(TMul#(sz_csr_strb, BYTE_WIDTH), BYTE_WIDTH, sz_csr_strb)
    );

    Clock fastClock <- exposeCurrentClock;
    Reset fastReset <- exposeCurrentReset;


    SyncFIFOIfc#(Axi4LiteWrAddr#(sz_csr_addr)) cntrlWrAddrFifo <- mkSyncFIFO(2, slowClock,slowReset, fastClock);
    SyncFIFOIfc#(Axi4LiteWrData#(sz_csr_strb)) cntrlWrDataFifo <- mkSyncFIFO(2, slowClock,slowReset, fastClock);
    SyncFIFOIfc#(Axi4LiteWrResp) cntrlWrRespFifo <- mkSyncFIFO(2, fastClock,fastReset, slowClock);
    SyncFIFOIfc#(Axi4LiteRdAddr#(sz_csr_addr)) cntrlRdAddrFifo <- mkSyncFIFO(2, slowClock,slowReset, fastClock);
    SyncFIFOIfc#(Axi4LiteRdData#(sz_csr_strb)) cntrlRdDataFifo <- mkSyncFIFO(2, fastClock,fastReset, slowClock);

    FIFOF#(CsrWriteRequest#(t_csr_addr, t_csr_data)) writeReqQ <- mkFIFOF;
    FIFOF#(CsrWriteResponse) writeRespQ <- mkFIFOF;
    FIFOF#(CsrReadRequest#(t_csr_addr)) readReqQ <- mkFIFOF;
    FIFOF#(CsrReadResponse#(t_csr_data)) readRespQ <- mkFIFOF;

    let cntrlAxilSlave <- mkRawAxi4LiteSlave(
        convertSyncFifoToFifoIn(cntrlWrAddrFifo),
        convertSyncFifoToFifoIn(cntrlWrDataFifo),
        convertSyncFifoToFifoOut(cntrlWrRespFifo),

        convertSyncFifoToFifoIn(cntrlRdAddrFifo),
        convertSyncFifoToFifoOut(cntrlRdDataFifo),
        clocked_by slowClock,
        reset_by slowReset
    );

    rule handleRead;
        cntrlRdAddrFifo.deq;

        readReqQ.enq(CsrReadRequest{
            addr: unpack(cntrlRdAddrFifo.first.arAddr)
        });
    endrule

    rule forwardReadResp;
        readRespQ.deq;
        cntrlRdDataFifo.enq(Axi4LiteRdData{rResp: 0, rData: unpack(pack(readRespQ.first.data))});
    endrule

    rule handleWrite;
        cntrlWrAddrFifo.deq;
        cntrlWrDataFifo.deq;
        writeReqQ.enq(CsrWriteRequest{
            addr: unpack(cntrlWrAddrFifo.first.awAddr),
            data: unpack(cntrlWrDataFifo.first.wData)
        });
    endrule

    rule forwardWriteResp;
        writeRespQ.deq;
        cntrlWrRespFifo.enq(0);
    endrule

    interface cntrlAxil = cntrlAxilSlave;
    interface csrWriteClt = toGPClient(writeReqQ, writeRespQ);
    interface csrReadClt = toGPClient(readReqQ, readRespQ);
endmodule


typedef struct {
    DmaReqSrcType initiator;
    QPN sqpn;
} UserLogicBluerdmaDmaProxyCustomDataH2c deriving(Bits, FShow);

typedef struct {
    DmaReqSrcType initiator;
    QPN sqpn;
    PSN psn;
} UserLogicBluerdmaDmaProxyCustomDataC2h deriving(Bits, FShow);


interface BluerdmaDmaProxyForRQ;
    interface Server#(DmaWriteReq, DmaWriteResp) blueSideWriteSrv;
    interface UserLogicDmaWriteClt userlogicSideWriteClt;
endinterface

(* synthesize *)
module mkBluerdmaDmaProxyForRQ(BluerdmaDmaProxyForRQ);

    FIFOF#(DmaWriteReq) blueSideReqQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hReq) userLogicSideReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) blueSideRespQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hResp) userLogicSideRespQ <- mkFIFOF;


    // rule debug;
    //     if (!blueSideReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkBluerdmaDmaProxyForRQ blueSideReqQ");
    //     end
    //     if (!userLogicSideReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkBluerdmaDmaProxyForRQ userLogicSideReqQ");
    //     end
    //     if (!blueSideRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkBluerdmaDmaProxyForRQ blueSideRespQ");
    //     end
    //     if (!userLogicSideRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkBluerdmaDmaProxyForRQ userLogicSideRespQ");
    //     end
    // endrule



    rule forwardReq;
        blueSideReqQ.deq;
        let inReq = blueSideReqQ.first;
        let outReq = UserLogicDmaC2hReq{
            addr: inReq.metaData.startAddr,
            len: zeroExtend(pack(inReq.metaData.len)),
            dataStream: dataStream2DataStreamEnLeftAlign(reverseStream(inReq.dataStream))
        };
        outReq.dataStream.byteEn = swapEndianBit(outReq.dataStream.byteEn);

        userLogicSideReqQ.enq(outReq);
    endrule

    rule forwardResp;
        userLogicSideRespQ.deq;
        blueSideRespQ.enq(
            DmaWriteResp{
                isRespErr: False
            }
        );
    endrule

    interface blueSideWriteSrv = toGPServer(blueSideReqQ, blueSideRespQ);
    interface userlogicSideWriteClt = toGPClient(userLogicSideReqQ, userLogicSideRespQ);

endmodule






interface XdmaGearbox;
    interface UserLogicDmaReadWideClt h2cStreamClt;
    interface UserLogicDmaWriteWideClt c2hStreamClt;
    interface UserLogicDmaReadSrv h2cStreamSrv;
    interface UserLogicDmaWriteSrv c2hStreamSrv;
endinterface


`ifdef IS_250MHZ_512BITS
(* synthesize *)
module mkXdmaBypassGearbox(XdmaGearbox ifc);
    
    FIFOF#(UserLogicDmaH2cReq) h2cReqQ <- mkPipelineFIFOF;
    FIFOF#(UserLogicDmaH2cResp) h2cRespQ <- mkPipelineFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) c2hReqQ <- mkPipelineFIFOF;
    FIFOF#(UserLogicDmaC2hResp) c2hRespQ <- mkPipelineFIFOF;
    interface UserLogicDmaReadWideClt h2cStreamClt;
        interface Get request;
            method ActionValue#(UserLogicDmaH2cReq) get;
                h2cReqQ.deq;
                return h2cReqQ.first;
            endmethod
        endinterface

        interface Put response;
            method Action put(UserLogicDmaH2cWideResp in);
                let resp = UserLogicDmaH2cResp {
                    dataStream: DataStreamEn {
                        data: in.dataStream.data,
                        byteEn: in.dataStream.byteEn,
                        isFirst: in.dataStream.isFirst,
                        isLast: in.dataStream.isLast
                    }
                };
                h2cRespQ.enq(resp);
            endmethod
        endinterface
    endinterface

    interface UserLogicDmaWriteWideClt c2hStreamClt;
        interface Get request;
            method ActionValue#(UserLogicDmaC2hWideReq) get;
                c2hReqQ.deq;
                return c2hReqQ.first;
            endmethod
        endinterface

        interface Put response;
            method Action put(UserLogicDmaC2hResp e);
                c2hRespQ.enq(e);
            endmethod
        endinterface
    endinterface

    interface UserLogicDmaReadWideSrv h2cStreamSrv;
        interface Get response;
            method ActionValue#(UserLogicDmaH2cResp) get;
                h2cRespQ.deq;
                return h2cRespQ.first;
            endmethod
        endinterface

        interface Put request;
            method Action put(UserLogicDmaH2cReq e);
                h2cReqQ.enq(e);
            endmethod
        endinterface

    endinterface

    interface UserLogicDmaWriteWideSrv c2hStreamSrv;
        interface Get response;
            method ActionValue#(UserLogicDmaC2hResp) get;
                c2hRespQ.deq;
                return c2hRespQ.first;
            endmethod
        endinterface

        interface Put request;
            method Action put(UserLogicDmaC2hReq e);
                let req = UserLogicDmaC2hWideReq{
                    addr: e.addr,
                    len: e.len,
                    dataStream: DataStreamWideEn{
                        data: e.dataStream.data,
                        byteEn: e.dataStream.byteEn,
                        isFirst: e.dataStream.isFirst,
                        isLast: e.dataStream.isLast
                    }
                };
                c2hReqQ.enq(req);
            endmethod
        endinterface
    endinterface
endmodule

`else  // IS_250MHZ_512BITS

(* synthesize *)
module mkXdmaGearbox(Clock slowClock, Reset slowReset, XdmaGearbox ifc);
    
    Clock fastClock <- exposeCurrentClock;
    Reset fastReset <- exposeCurrentReset;
    ClockDividerIfc divClk <- mkClockDivider(2);
    
    Store#(UInt#(2),UserLogicDmaH2cReq,0) h2cStreamReqQStore <- mkRegVectorStore(fastClock, slowClock);
    Store#(UInt#(2),UserLogicDmaC2hResp,0) c2hStreamRespQStore <- mkRegVectorStore(slowClock, fastClock);

    AlignedFIFO#(UserLogicDmaH2cReq) h2cStreamReqQ <- mkAlignedFIFO(
        fastClock, fastReset,
        slowClock, slowReset,
        h2cStreamReqQStore,
        divClk.clockReady,
        True
    );

    Gearbox#(XDMA_GEARBOX_WIDE_VECTOR_LEN, XDMA_GEARBOX_NARROW_VECTOR_LEN, Maybe#(UserLogicDmaH2cResp)) h2cRespGearbox <- mkNto1Gearbox(
        slowClock, slowReset,
        fastClock, fastReset
    );


    Gearbox#(XDMA_GEARBOX_NARROW_VECTOR_LEN, XDMA_GEARBOX_WIDE_VECTOR_LEN, Maybe#(UserLogicDmaC2hReq)) c2hReqGearbox <- mk1toNGearbox(
        fastClock, fastReset,    
        slowClock, slowReset
    );

    AlignedFIFO#(UserLogicDmaC2hResp) c2hStreamRespQ <- mkAlignedFIFO(
        slowClock, slowReset,
        fastClock, fastReset,
        c2hStreamRespQStore,
        True,
        divClk.clockReady
    );

    FIFOF#(UserLogicDmaH2cResp) h2cRespQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hReq) c2hReqQ <- mkFIFOF;
    
    Reg#(Bool) isCurrentC2hReqAnOddBeatReg <- mkReg(True);
    Reg#(Bool) needExtraEmptyCh2ReqBeatReg <- mkReg(False);

    rule forwardH2cResp;
        // use this rule to filter out Invalid resp.
        h2cRespGearbox.deq;
        
        if (h2cRespGearbox.first[0] matches tagged Valid .resp) begin
            h2cRespQ.enq(resp);
        end
    endrule

    rule forwardC2hReq;
        // use this rule to insert a invalid tail if the tail 256 bits is not used.
        Vector#(XDMA_GEARBOX_NARROW_VECTOR_LEN, Maybe#(UserLogicDmaC2hReq)) out;
        if (needExtraEmptyCh2ReqBeatReg) begin
            out[0] = tagged Invalid;
            c2hReqGearbox.enq(out);
            isCurrentC2hReqAnOddBeatReg <= True;
            needExtraEmptyCh2ReqBeatReg <= False;
        end 
        else begin
            out[0] = tagged Valid c2hReqQ.first;
            c2hReqGearbox.enq(out);
            c2hReqQ.deq;
            isCurrentC2hReqAnOddBeatReg <= !isCurrentC2hReqAnOddBeatReg;
        
            if (isCurrentC2hReqAnOddBeatReg && c2hReqQ.first.dataStream.isLast) begin
                needExtraEmptyCh2ReqBeatReg <= True;
            end
        end
    endrule

    interface UserLogicDmaReadWideClt h2cStreamClt;
        interface Get request;
            method ActionValue#(UserLogicDmaH2cReq) get;
                h2cStreamReqQ.deq;
                return h2cStreamReqQ.first;
            endmethod
        endinterface

        interface Put response;
            method Action put(UserLogicDmaH2cWideResp in);
                ByteEn headPartEn = truncate(in.dataStream.byteEn);
                DATA headPartData = truncate(in.dataStream.data);
                ByteEn tailPartEn = truncateLSB(in.dataStream.byteEn);
                DATA tailPartData = truncateLSB(in.dataStream.data);

                UserLogicDmaH2cResp out0;
                UserLogicDmaH2cResp out1;


                out0.dataStream.byteEn = headPartEn;
                out1.dataStream.byteEn = tailPartEn;
                out0.dataStream.data = headPartData;
                out1.dataStream.data = tailPartData;

                Bool isTailPartValid = !isZeroR(tailPartEn);
                out0.dataStream.isFirst = in.dataStream.isFirst;
                out1.dataStream.isFirst = False;
                if (!isTailPartValid) begin
                    out0.dataStream.isLast = in.dataStream.isLast;
                    out1.dataStream.isLast = False;
                end 
                else begin
                    out0.dataStream.isLast = False;
                    out1.dataStream.isLast = in.dataStream.isLast;
                end

                Vector#(2, Maybe#(UserLogicDmaH2cResp)) outVec;

                outVec[0] = tagged Valid out0;
                outVec[1] = isTailPartValid ? tagged Valid out1 : tagged Invalid;

                h2cRespGearbox.enq(outVec);
            endmethod
        endinterface
    endinterface

    interface UserLogicDmaWriteWideClt c2hStreamClt;
        interface Get request;
            method ActionValue#(UserLogicDmaC2hWideReq) get;
                c2hReqGearbox.deq;
                let headPartMaybe = c2hReqGearbox.first[0];
                let tailPartMaybe = c2hReqGearbox.first[1];
                immAssert(
                    isValid(headPartMaybe),
                    "XdmaGearbox c2h head part valid check err @ mkXdmaGearbox",
                    $format(
                        "expect head part to always be valid"
                    )
                );
                
                UserLogicDmaC2hWideReq out = ?;
    
                let headPart = fromMaybe(?, headPartMaybe);
                out.addr = headPart.addr;
                out.len = headPart.len;
                out.dataStream.isFirst = headPart.dataStream.isFirst;
                if (tailPartMaybe matches tagged Valid .tailPart) begin
                    out.dataStream.data = {tailPart.dataStream.data, headPart.dataStream.data};
                    out.dataStream.isLast = tailPart.dataStream.isLast;
                    out.dataStream.byteEn = {tailPart.dataStream.byteEn, headPart.dataStream.byteEn};
                end 
                else begin
                    out.dataStream.data = {0, headPart.dataStream.data};
                    out.dataStream.isLast = headPart.dataStream.isLast;
                    out.dataStream.byteEn = {0, headPart.dataStream.byteEn};
                end

                return out;
            endmethod
        endinterface

        interface Put response;
            method Action put(UserLogicDmaC2hResp e);
                c2hStreamRespQ.enq(e);
            endmethod
        endinterface
    endinterface

    interface UserLogicDmaReadWideSrv h2cStreamSrv;
        interface Get response;
            method ActionValue#(UserLogicDmaH2cResp) get;
                h2cRespQ.deq;
                return h2cRespQ.first;
            endmethod
        endinterface

        interface Put request;
            method Action put(UserLogicDmaH2cReq e);
                h2cStreamReqQ.enq(e);
            endmethod
        endinterface

    endinterface

    interface UserLogicDmaWriteWideSrv c2hStreamSrv;
        interface Get response;
            method ActionValue#(UserLogicDmaC2hResp) get;
                c2hStreamRespQ.deq;
                return c2hStreamRespQ.first;
            endmethod
        endinterface

        interface Put request;
            method Action put(UserLogicDmaC2hReq e);
                c2hReqQ.enq(e);
            endmethod
        endinterface
    endinterface
endmodule
`endif  // IS_250MHZ_512BITS



interface FakeXdma;
    interface AxiStream512FifoIn   axiStreamTxUdp;
    interface Get#(AxiStream512)   axiStreamRxUdp;
    interface UserLogicDmaReadWideSrv xdmaH2cSrv;
    interface UserLogicDmaWriteWideSrv xdmaC2hSrv;
    interface Client#(CsrAddr, CsrData) barReadClt;
    interface Client#(Tuple2#(CsrAddr, CsrData), Bool) barWriteClt;
endinterface



typedef SizeOf#(UserLogicDmaLen)                            FAKE_XDMA_MAX_BURST_WIDTH;          // 1MB
typedef DATA_BUS_WIDE_WIDTH                                 FAKE_XDMA_BEAT_DATA_BIT_WIDTH;      // 512-bit
typedef TDiv#(FAKE_XDMA_BEAT_DATA_BIT_WIDTH, BYTE_WIDTH)    FAKE_XDMA_BEAT_DATA_BYTE_WIDTH;     // 64B



typedef Bit#(TAdd#(TLog#(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH),1)) FakeXdmaBeatByteNum;
typedef Bit#(TAdd#(TLog#(FAKE_XDMA_BEAT_DATA_BIT_WIDTH),1)) FakeXdmaBeatBitNum;

typedef TSub#(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH,1) FAKE_XDMA_BEAT_DATA_BYTE_OFFFSET_MASK;


typedef struct {
    Bool isFirst;
    Bool isLast;
    FakeXdmaBeatByteNum beatValidByteCnt;
} FakeXdmaMemReadBeatExtraInfo deriving(Bits, FShow);

typedef struct {
    FakeXdmaBeatByteNum leftShiftByteCnt;
    FakeXdmaBeatByteNum rightShiftByteCnt;
} FakeXdmaMemReadStreamExtraInfo deriving(Bits, FShow);

typedef struct {
    Bool isFirst;
    Bool isLast;
    // FakeXdmaBeatByteNum beatValidByteCnt;
    ByteEnWide byteEn;
} FakeXdmaMemWriteBeatExtraInfo deriving(Bits, FShow);


function FakeXdmaBeatByteNum calcFragByteNumFromByteEnWide(ByteEnWide fragByteEn);
    FakeXdmaBeatByteNum byteEnBitNum = 0;
    for (
        Integer idx = 0;
        idx < valueOf(DATA_BUS_WIDE_BYTE_WIDTH);
        idx = idx + 1
    ) begin
        if (fragByteEn[idx] == 1) begin
            byteEnBitNum = fromInteger(idx+1);
        end
    end
    return byteEnBitNum;
endfunction

module mkFakeXdma(Integer id, Clock cmacRxTxClk, Reset cmacRxTxRst, FakeXdma ifc);
    FIFOF#(UserLogicDmaH2cReq) xdmaH2cReqQ <- makeDelayQueue(20);
    FIFOF#(UserLogicDmaH2cWideResp) xdmaH2cRespQ <- mkFIFOF;
    FIFOF#(UserLogicDmaC2hWideReq) xdmaC2hReqQ <- makeDelayQueue(20);
    FIFOF#(UserLogicDmaC2hResp) xdmaC2hRespQ <- mkFIFOF;

    BRAM_Configure cfg = defaultValue;
    cfg.allowWriteResponseBypass = False;
    cfg.memorySize = 1024*1024; // 64 MB, word size is 64B
    // BRAM2PortBE#(ADDR, DATA_WIDE, SizeOf#(ByteEnWide)) hostMem <- mkBRAM2ServerBE(cfg);
    MockHost#(Bit#(32), Bit#(512), 64, CsrAddr, CsrData) mockHost <- mkMockHost(cfg, cmacRxTxClk, cmacRxTxRst);
    let hostMem = mockHost.hostMem;
    

    Reg#(Bool) currentNotFinished <- mkReg(False);
    FIFOF#(FakeXdmaMemReadBeatExtraInfo) respBeatInfoQ <- mkSizedFIFOF(10);
    FIFOF#(FakeXdmaMemReadStreamExtraInfo) respStreamInfoQ <- mkSizedFIFOF(10);

    Reg#(UserLogicDmaLen) bytesLeftReg <- mkRegU;
    Reg#(ADDR) currentAddrH2cReg <- mkRegU;
    Reg#(ADDR) currentAddrC2hReg <- mkRegU;

    Reg#(Tuple2#(DATA_WIDE, FakeXdmaMemReadBeatExtraInfo)) prevMemReadRespReg <- mkRegU;

    FIFOF#(DATA_WIDE) memReadRespQ <- mkSizedFIFOF(10);
    mkConnection(memReadRespQ.enq, hostMem.portA.response.get);  // convert get to fifof to use notEmpty

    Integer readRespHandleStateHandleFirst=0;
    Integer readRespHandleStateHandleMiddle=1;
    Reg#(Bit#(1)) readRespHandleStateReg <- mkReg(0);

    Reg#(Tuple2#(DATA_WIDE, FakeXdmaMemWriteBeatExtraInfo)) prevMemWriteReqReg <- mkRegU;

    Reg#(Bool) writeReqNeedExtraBeatReg <- mkReg(False);


    // rule debug;
    //     if (!xdmaH2cReqQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMTPY_QUEUE_DETECTED: mkFakeXdma xdmaH2cReqQ");
    //     end
    //     if (!respBeatInfoQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma respBeatInfoQ");
    //     end
    //     if (!respStreamInfoQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma respStreamInfoQ");
    //     end

    //     if (!xdmaH2cReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma xdmaH2cReqQ");
    //     end
    //     if (!xdmaH2cRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma xdmaH2cRespQ");
    //     end
    //     if (!xdmaC2hReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma xdmaC2hReqQ");
    //     end
    //     if (!xdmaC2hRespQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkFakeXdma xdmaC2hRespQ");
    //     end
    // endrule

    rule handleH2cReq;
        let req = xdmaH2cReqQ.first;
        let len = req.len;
        let addr = req.addr;

        // $display("mock dma %d receive H2C request: Addr=", id, fshow(req.addr), "Len=", fshow(req.len));

        immAssert(
            len != 0,
            "DMA H2C request len is 0 @ mkFakeXdma",
            $format(
                "request should not be 0 in length, request = ", fshow(xdmaH2cReqQ.first)
            )
        );

        FakeXdmaBeatByteNum addrAlignOffset = truncate(addr & fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_OFFFSET_MASK)));
        FakeXdmaBeatByteNum addrAlignRemainder = fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH)) - addrAlignOffset; 

            
        if (currentNotFinished == False) begin
            UserLogicDmaLen byteLeft = len;

            let isLastBeat = byteLeft <= zeroExtend(addrAlignRemainder);
            let curAddr = addr;

            hostMem.portA.request.put(BRAMRequestBE{
                writeen: 0,
                responseOnWrite: False,
                address: truncate(curAddr >> fromInteger(valueOf(TLog#(SizeOf#(ByteEnWide))))),
                datain: ?
            });
            $display("time=%0t: ", $time, "MockBram read address 1:", fshow(curAddr));

            respBeatInfoQ.enq(FakeXdmaMemReadBeatExtraInfo{isFirst: True, isLast: isLastBeat, beatValidByteCnt: isLastBeat ? truncate(byteLeft) : addrAlignRemainder});
            respStreamInfoQ.enq(FakeXdmaMemReadStreamExtraInfo{leftShiftByteCnt: addrAlignRemainder, rightShiftByteCnt: addrAlignOffset});
            if (isLastBeat) begin
                currentNotFinished <= False;
                xdmaH2cReqQ.deq;
            end 
            else begin
                currentNotFinished <= True;
                bytesLeftReg <= byteLeft - zeroExtend(addrAlignRemainder);
                currentAddrH2cReg <= curAddr + fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            end
        end 
        else begin
            // For a big request, we have to split it into multi BRAM read requests
            let isLastBeat = bytesLeftReg <= fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            FakeXdmaBeatByteNum beatValidByteCnt = isLastBeat ? truncate(bytesLeftReg) : fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            let curAddr = currentAddrH2cReg;
            hostMem.portA.request.put(BRAMRequestBE{
                writeen: 0,
                responseOnWrite: False,
                address: truncate(curAddr >> fromInteger(valueOf(TLog#(SizeOf#(ByteEnWide))))),
                datain: ?
            });
            $display("time=%0t: ", $time, "MockBram read address 2:", fshow(curAddr));
            
            respBeatInfoQ.enq(FakeXdmaMemReadBeatExtraInfo{isFirst: False, isLast: isLastBeat, beatValidByteCnt: beatValidByteCnt});
            if (isLastBeat) begin
                currentNotFinished <= False;
                xdmaH2cReqQ.deq;
            end 
            else begin
                currentNotFinished <= True;
                bytesLeftReg <= bytesLeftReg - zeroExtend(beatValidByteCnt);
                currentAddrH2cReg <= currentAddrH2cReg + fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            end
        end
    endrule

    rule handleC2hReq if (!writeReqNeedExtraBeatReg);
        let req = xdmaC2hReqQ.first;
        let len = req.len;
        let addr = req.addr;
        let stream = req.dataStream;
        $display("mock dma %d receive C2H request: Addr=", id, fshow(req.addr), "Len=", fshow(req.len), "Data=", fshow(req.dataStream));

        immAssert(
            req.len != 0,
            "DMA C2H request len is 0 @ mkFakeXdma",
            $format(
                "request should not be 0 in length, request = ", fshow(xdmaC2hReqQ.first)
            )
        );

        FakeXdmaBeatByteNum addrAlignOffset = truncate(addr & fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_OFFFSET_MASK)));
        FakeXdmaBeatByteNum addrAlignRemainder = fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH)) - addrAlignOffset; 

        xdmaC2hReqQ.deq;
        FakeXdmaBeatByteNum curReqValidByteCnt = calcFragByteNumFromByteEnWide(stream.byteEn);
        FakeXdmaBeatByteNum leftShiftByte = zeroExtend(addrAlignOffset);
        FakeXdmaBeatByteNum rightShiftByte = zeroExtend(addrAlignRemainder);
        FakeXdmaBeatBitNum leftShiftBit = zeroExtend(leftShiftByte) << 3;
        FakeXdmaBeatBitNum rightShiftBit = zeroExtend(rightShiftByte) << 3;

        if (stream.isFirst) begin
            let outData = stream.data << leftShiftBit;
            let byteEn = stream.byteEn << leftShiftByte;
            let curAddr = addr;
            hostMem.portB.request.put(BRAMRequestBE{
                writeen: byteEn,
                responseOnWrite: False,
                address: unpack(truncate(curAddr >> fromInteger(valueOf(TLog#(SizeOf#(ByteEnWide)))))),
                datain: outData
            });
            $display("time=%0t: ", $time, "MockBram write address 1:", fshow(curAddr), ", outData=", fshow(outData), ", byteEn=", fshow(byteEn));

            currentAddrC2hReg <= curAddr + fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            prevMemWriteReqReg <= tuple2(stream.data, FakeXdmaMemWriteBeatExtraInfo{isFirst: stream.isFirst, isLast: stream.isLast, byteEn: stream.byteEn});
        end 
        else begin
            let {prevReqData, prevReqBeatInfo} = prevMemWriteReqReg;
            let outData = stream.data << leftShiftBit | prevReqData >> rightShiftBit;
            let byteEn = stream.byteEn << leftShiftByte | prevReqBeatInfo.byteEn >> rightShiftByte;

            let curAddr = currentAddrC2hReg;
            
            hostMem.portB.request.put(BRAMRequestBE{
                writeen: byteEn,
                responseOnWrite: False,
                address: unpack(truncate(curAddr >> fromInteger(valueOf(TLog#(SizeOf#(ByteEnWide)))))),
                datain: outData
            });
            $display("time=%0t: ", $time, "MockBram write address 2:", fshow(curAddr), ", outData=", fshow(outData), ", byteEn=", fshow(byteEn));

            currentAddrC2hReg <= currentAddrC2hReg + fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH));
            prevMemWriteReqReg <= tuple2(stream.data, FakeXdmaMemWriteBeatExtraInfo{isFirst: stream.isFirst, isLast: stream.isLast, byteEn: stream.byteEn});
        end

        
        let hasMoreData = unpack(pack({1'b0, stream.byteEn})[rightShiftByte]);
        if (stream.isLast) begin
            if (hasMoreData) begin
                writeReqNeedExtraBeatReg <= True;
            end 
            else begin
                xdmaC2hRespQ.enq(UserLogicDmaC2hResp{});
            end
        end
    endrule

    rule handleReqExtraBeat if (writeReqNeedExtraBeatReg);
        writeReqNeedExtraBeatReg <= False;
        let addr = currentAddrC2hReg;
        

        let {prevReqData, prevReqBeatInfo} = prevMemWriteReqReg;

        FakeXdmaBeatByteNum addrAlignOffset = truncate(addr & fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_OFFFSET_MASK)));
        FakeXdmaBeatByteNum addrAlignRemainder = fromInteger(valueOf(FAKE_XDMA_BEAT_DATA_BYTE_WIDTH)) - addrAlignOffset; 
        FakeXdmaBeatByteNum rightShiftByte = zeroExtend(addrAlignRemainder);
        FakeXdmaBeatBitNum rightShiftBit = zeroExtend(rightShiftByte) << 3;
        
        let outData = prevReqData >> rightShiftBit;
        let byteEn = prevReqBeatInfo.byteEn >> rightShiftByte;
        let curAddr = currentAddrC2hReg;
        hostMem.portB.request.put(BRAMRequestBE{
            writeen: byteEn,
            responseOnWrite: False,
            address: unpack(truncate(curAddr >> fromInteger(valueOf(TLog#(SizeOf#(ByteEnWide)))))),
            datain: outData
        });
        xdmaC2hRespQ.enq(UserLogicDmaC2hResp{});
        $display("time=%0t: ", $time, "MockBram write address 3:", fshow(curAddr));
    endrule



    rule ruleHandleRespFirst if (readRespHandleStateReg == fromInteger(readRespHandleStateHandleFirst));
        let newMemReadResp = memReadRespQ.first;
        memReadRespQ.deq;
        respBeatInfoQ.deq;
        prevMemReadRespReg <= tuple2(newMemReadResp, respBeatInfoQ.first);
        readRespHandleStateReg <= fromInteger(readRespHandleStateHandleMiddle);
    endrule


    rule ruleHandleRespMiddle if (readRespHandleStateReg == fromInteger(readRespHandleStateHandleMiddle));
        let readStreamInfo = respStreamInfoQ.first;
        let {prevMemReadResp, prevBeatInfo} = prevMemReadRespReg;

        FakeXdmaBeatBitNum leftShiftBit = zeroExtend(readStreamInfo.leftShiftByteCnt) << 3;
        FakeXdmaBeatBitNum rightShiftBit = zeroExtend(readStreamInfo.rightShiftByteCnt) << 3;

        
        if (prevBeatInfo.isLast) begin

            let outData = (prevMemReadResp >> rightShiftBit);
            let outEn = (
                prevBeatInfo.isFirst ? 
                (1 << prevBeatInfo.beatValidByteCnt) -1 :
                (1 << (prevBeatInfo.beatValidByteCnt - readStreamInfo.rightShiftByteCnt)) - 1
            );

            let resp = UserLogicDmaH2cWideResp{
                dataStream: DataStreamWideEn{
                    data: outData,
                    isFirst: prevBeatInfo.isFirst,
                    isLast: True,
                    byteEn: outEn
                }
            };
            xdmaH2cRespQ.enq(resp);
            respStreamInfoQ.deq;

            if (memReadRespQ.notEmpty) begin
                memReadRespQ.deq;
                respBeatInfoQ.deq;
                
                prevMemReadRespReg <= tuple2(memReadRespQ.first, respBeatInfoQ.first);
            end 
            else begin
                readRespHandleStateReg <= fromInteger(readRespHandleStateHandleFirst);
            end

        end 
        else begin
            
            let newBeatInfo = respBeatInfoQ.first;
            let newMemReadResp = memReadRespQ.first;
            
            Bool hasMoreData = readStreamInfo.rightShiftByteCnt < newBeatInfo.beatValidByteCnt;
            let outData = (prevMemReadResp >> rightShiftBit) | (newMemReadResp << leftShiftBit);
            let outEn = hasMoreData ? -1 : (1 << (readStreamInfo.leftShiftByteCnt + newBeatInfo.beatValidByteCnt)) - 1;
            
            let resp = UserLogicDmaH2cWideResp{
                dataStream: DataStreamWideEn{
                    data: outData,
                    isFirst: prevBeatInfo.isFirst,
                    isLast: !hasMoreData,
                    byteEn: outEn
                }
            };
            xdmaH2cRespQ.enq(resp);

            if (!hasMoreData) begin
                readRespHandleStateReg <= fromInteger(readRespHandleStateHandleFirst);
                respStreamInfoQ.deq;
            end

            memReadRespQ.deq;
            respBeatInfoQ.deq;
            
            prevMemReadRespReg <= tuple2(newMemReadResp, respBeatInfoQ.first);

        end
    endrule

    interface axiStreamTxUdp = mockHost.axiStreamTxUdp;
    interface axiStreamRxUdp = mockHost.axiStreamRxUdp;
    interface xdmaH2cSrv = toGPServer(xdmaH2cReqQ, xdmaH2cRespQ);
    interface xdmaC2hSrv = toGPServer(xdmaC2hReqQ, xdmaC2hRespQ);
    interface barWriteClt = mockHost.barWriteClt;
    interface barReadClt = mockHost.barReadClt;
endmodule




module makeDelayQueue#(Integer delayCyclesInt)(FIFOF#(tData)) provisos(Bits#(tData, szData));

    FIFOF#(tData) firstFifo <- mkFIFOF;
    FIFOF#(tData) lastFifo <- mkFIFOF;

    FIFOF#(tData) prevFifo = firstFifo;

    for (Integer idx = 0; idx < delayCyclesInt-2; idx = idx + 1) begin
        FIFOF#(tData) midFifo <- mkFIFOF;
        mkConnection(toGet(prevFifo), toPut(midFifo));
        prevFifo = midFifo;
    end

    mkConnection(toGet(prevFifo), toPut(lastFifo));


    method notFull = firstFifo.notFull;
    method enq = firstFifo.enq;
    
    method notEmpty = lastFifo.notEmpty;
    method first = lastFifo.first;
    method deq = lastFifo.deq;

    method clear = firstFifo.clear;
endmodule