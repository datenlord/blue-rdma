import Connectable :: *;
import ClientServer :: *;
import GetPut :: *;
import FIFOF :: *;
import PAClib :: *;
import Clocks :: *;
import BRAM :: *;

import RQ :: *;
import QPContext :: *;
import MetaData :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import RdmaUtils :: *;
import PrimUtils :: *;
import StmtFSM::*;
import Axi4LiteTypes :: *;
import SemiFifo :: *;
import UdpIpEthCmacRxTx::*;

import ExtractAndPrependPipeOut :: *;

import MemRegionAndAddressTranslate :: *;
import PayloadCon :: *;
import Headers :: *;
import Ports :: *;
import StreamHandler :: *;

import XdmaWrapper :: *;
import UserLogicTypes :: *;
import RegisterBlock :: *;
import EthernetTypes :: *;
import XilinxCmacController::*;
import AxiStreamTypes::*;


import Top :: *;
import SendQ  ::*;
import SoftReset :: *;

`define TEST_QPN_IDX_PART 'h3
`define TEST_QPN_KEY_PART 'h611

`define TEST_MR_IDX_PART 'h0
`define TEST_MR_KEY_PART 'h6622
`define TEST_MR_START_VA 'h0
`define TEST_MR_LENGTH   'h4000000
`define TEST_MR_FIRST_PGT_IDX   'h200

`define TEST_PGT_FIRST_ENTRY_PN 'h000C

`define TEST_PD_HANDLER   'h7890

`define TEST_WR_ADDR `TEST_MR_START_VA + 1
`define TEST_WR_LEN  1023




(* doc = "testcase" *)
module mkTestTop(Empty);
    

    Clock sysClk <- mkAbsoluteClock(0, 10);
    Clock resetManagerClock <- mkAbsoluteClock(0, 1);
    let rst1 <- mkAsyncResetFromCR(0, sysClk);

    let dutReset <- mkReset(1, False, sysClk, clocked_by sysClk, reset_by rst1);
    
    let globalSoftReset <- mkGlobalSoftReset( resetManagerClock, noReset, clocked_by sysClk, reset_by rst1);
    
    let dutRst <- mkResetEither(dutReset.new_rst, rst1, clocked_by sysClk, reset_by rst1);
    let dut <- mkTestTopInner(clocked_by sysClk, reset_by dutRst);

    let crossWire <- mkNullCrossingWire(sysClk, dut.csrSoftResetSignal);

    rule doDoGlobalSoftReset;
        
        if (crossWire) begin
            $display("crossWire=", fshow(crossWire));
            globalSoftReset.doReset;
        end
    endrule

    rule mockSoftResetAction;
        if (globalSoftReset.resetOut == False) begin
            dutReset.assertReset;
        end
    endrule
endmodule

interface TestTopInner;
    (* prefix = "", always_enabled *)
    method Bool csrSoftResetSignal;
endinterface

(* doc = "testcase" *)
module mkTestTopInner(TestTopInner);

    Clock rdmaClock <- exposeCurrentClock;
    Reset rdmaReset <- exposeCurrentReset;

    Clock dmacClock <- exposeCurrentClock;
    Reset dmacReset <- exposeCurrentReset;

    Clock udpClock <- exposeCurrentClock;
    Reset udpReset <- exposeCurrentReset;

    Clock cmacRxTxClk <- mkAbsoluteClock(0, 7);  // about 322 MHz
    // Clock cmacRxTxClk <- mkAbsoluteClock(0, 10);
    Reset cmacRxTxRst <- mkSyncReset(2, udpReset, cmacRxTxClk);

    RdmaUserLogicWithoutXdmaAndCmacWrapper topA <- mkRdmaUserLogicWithoutXdmaAndCmacWrapper(udpClock, udpReset, dmacClock, dmacReset);

    FakeXdma fakeXdmaA <- mkFakeXdma(1, cmacRxTxClk, cmacRxTxRst);


`ifdef DO_BANDWIDTH_TEST
    let midLayer <- mkDmaReqMiddleLayerForBandwidthTest;
    mkConnection(midLayer.dmaReadSrv, topA.dmaReadClt);
    mkConnection(midLayer.dmaWriteSrv, topA.dmaWriteClt);
    mkConnection(fakeXdmaA.xdmaH2cSrv, midLayer.dmaReadClt);
    mkConnection(fakeXdmaA.xdmaC2hSrv, midLayer.dmaWriteClt);
`else    
    mkConnection(fakeXdmaA.xdmaH2cSrv, topA.dmaReadClt);
    mkConnection(fakeXdmaA.xdmaC2hSrv, topA.dmaWriteClt);
`endif

    SyncFIFOIfc#(CsrAddr) csrReadReqSyncFifo <- mkSyncFIFO(2, dmacClock, dmacReset, rdmaClock);
    mkConnection(fakeXdmaA.barReadClt.request, toPut(csrReadReqSyncFifo)); 

    SyncFIFOIfc#(CsrData) csrReadRespSyncFifo <- mkSyncFIFO(2, rdmaClock, rdmaReset, dmacClock);
    mkConnection(toGet(csrReadRespSyncFifo), fakeXdmaA.barReadClt.response); 

    SyncFIFOIfc#(Tuple2#(CsrAddr, CsrData)) csrWriteReqSyncFifo <- mkSyncFIFO(2, dmacClock, dmacReset, rdmaClock);
    mkConnection(fakeXdmaA.barWriteClt.request, toPut(csrWriteReqSyncFifo)); 

    SyncFIFOIfc#(Bool) csrWriteRespSyncFifo <- mkSyncFIFO(2, rdmaClock, rdmaReset, dmacClock);
    mkConnection(toGet(csrWriteRespSyncFifo), fakeXdmaA.barWriteClt.response); 


// `define __TXRX_MODEL_LOOPBACK_DELAYED
// `define __TXRX_MODEL_LOOPBACK_NONE_DELAY True
`define __TXRX_MODEL_CONNECT_TO_MOCK_HOST True

`ifdef __TXRX_MODEL_LOOPBACK_DELAYED

    // loop tx stream to rx stream with delay

    FIFOF#(AxiStream512) delayQ <- mkSizedFIFOF(8192);
    // loop tx stream to rx stream with delayed time so they won't interfere eachother.
    rule bufferTxStream;
        let d = topA.axiStreamTxOutUdp.first;
        topA.axiStreamTxOutUdp.deq;
        delayQ.enq(d);
        $display("time=%0t: ", $time, "udp send data and put to buffer ");
    endrule

    rule outputTxStream;
        let t <- $time;
        if (t > 16890) begin
            let d = delayQ.first;
            delayQ.deq;
            topA.axiStreamRxInUdp.put(d);
            $display("time=%0t: ", $time, "deq data from delayQ");
        end
    endrule

`elsif __TXRX_MODEL_LOOPBACK_NONE_DELAY

    // loop tx stream to rx stream without delay
    rule displayAndForwardWireData;
        let d = topA.axiStreamTxOutUdp.first;
        topA.axiStreamTxOutUdp.deq;
        topA.axiStreamRxInUdp.put(d);
        $display("time=%0t: ", $time, "udp send data: ", fshow(d));
    endrule

`elsif __TXRX_MODEL_CONNECT_TO_MOCK_HOST

    // connect rx and tx to MockHost

    SyncFIFOIfc#(AxiStream512) netIfcRxSyncFifo <- mkSyncFIFO(32, cmacRxTxClk, cmacRxTxRst, udpClock);
    mkConnection(fakeXdmaA.axiStreamRxUdp, toPut(netIfcRxSyncFifo), clocked_by cmacRxTxClk, reset_by cmacRxTxRst);
    mkConnection(toGet(netIfcRxSyncFifo), topA.axiStreamRxInUdp);

    SyncFIFOIfc#(AxiStream512) netIfcTxSyncFifo <- mkSyncFIFO(32, udpClock, udpReset, cmacRxTxClk);
    // mkConnection(toGet(topA.axiStreamTxOutUdp), toPut(netIfcTxSyncFifo));
    rule forwardUdpSendStream;
        if (netIfcTxSyncFifo.notFull) begin
            let txData = topA.axiStreamTxOutUdp.first;
            topA.axiStreamTxOutUdp.deq;
            netIfcTxSyncFifo.enq(txData);
            $display("time=%0t: ", $time, "forward udp send data to sync FIFO of CMAC");
        end
        else begin
            $display("time=%0t: ", $time, "!!!!!!!!!!!!!!!!!!!!!forward udp send data to sync FIFO of CMAC, but FIFO is FULL!!!!!!!!!!!!!!!");
        end
    endrule
    mkConnection(convertSyncFifoToFifoOut(netIfcTxSyncFifo), fakeXdmaA.axiStreamTxUdp, clocked_by cmacRxTxClk, reset_by cmacRxTxRst); 

`endif
    rule forwardBarReadReq;
        csrReadReqSyncFifo.deq;
        let inReq = csrReadReqSyncFifo.first;
        let outReq = CsrReadRequest{addr: inReq};
        topA.csrReadSrv.request.put(outReq);
        // $display("csr read req =", fshow(outReq));
    endrule

    rule forwardBarReadResp;
        let inResp <- topA.csrReadSrv.response.get;
        let outResp = inResp.data;
        csrReadRespSyncFifo.enq(outResp);
        // $display("csr read resp =", fshow(outResp));
    endrule

    rule forwardBarWriteReq;
        csrWriteReqSyncFifo.deq;
        let inReq = csrWriteReqSyncFifo.first;
        let outReq = CsrWriteRequest{addr: tpl_1(inReq), data: tpl_2(inReq)};
        topA.csrWriteSrv.request.put(outReq);
        // $display("csr write req = ", fshow(outReq));
    endrule

    rule forwardBarWriteResp;
        let inResp <- topA.csrWriteSrv.response.get;
        let outResp = True;
        csrWriteRespSyncFifo.enq(outResp);
    endrule


    method Bool csrSoftResetSignal = topA.csrSoftResetSignal;
endmodule




(* doc = "testcase" *)
module mkTestRdmaAndUserLogicWithoutUdp(Empty);

    Clock rdmaClock <- exposeCurrentClock;
    Reset rdmaReset <- exposeCurrentReset;

    Clock dmacClock <- exposeCurrentClock;
    Reset dmacReset <- exposeCurrentReset;

    Clock udpClock <- exposeCurrentClock;
    Reset udpReset <- exposeCurrentReset;

    Clock cmacRxTxClk <- mkAbsoluteClock(0, 7);  // about 322 MHz
    // Clock cmacRxTxClk <- mkAbsoluteClock(0, 10);
    Reset cmacRxTxRst <- mkSyncReset(2, rdmaReset, cmacRxTxClk);

    RdmaUserLogicWithoutXdmaAndUdpCmacWrapper topA <- mkRdmaUserLogicWithoutXdmaAndUdpCmacWrapper(dmacClock, dmacReset);

    FakeXdma fakeXdmaA <- mkFakeXdma(1, cmacRxTxClk, cmacRxTxRst, clocked_by dmacClock, reset_by dmacReset);

    mkConnection(fakeXdmaA.xdmaH2cSrv, topA.dmaReadClt);
    mkConnection(fakeXdmaA.xdmaC2hSrv, topA.dmaWriteClt);

    SyncFIFOIfc#(CsrAddr) csrReadReqSyncFifo <- mkSyncFIFO(2, dmacClock, dmacReset, rdmaClock);
    mkConnection(fakeXdmaA.barReadClt.request, toPut(csrReadReqSyncFifo), clocked_by dmacClock, reset_by dmacReset); 

    SyncFIFOIfc#(CsrData) csrReadRespSyncFifo <- mkSyncFIFO(2, rdmaClock, rdmaReset, dmacClock);
    mkConnection(toGet(csrReadRespSyncFifo), fakeXdmaA.barReadClt.response, clocked_by dmacClock, reset_by dmacReset); 

    SyncFIFOIfc#(Tuple2#(CsrAddr, CsrData)) csrWriteReqSyncFifo <- mkSyncFIFO(2, dmacClock, dmacReset, rdmaClock);
    mkConnection(fakeXdmaA.barWriteClt.request, toPut(csrWriteReqSyncFifo), clocked_by dmacClock, reset_by dmacReset); 

    SyncFIFOIfc#(Bool) csrWriteRespSyncFifo <- mkSyncFIFO(2, rdmaClock, rdmaReset, dmacClock);
    mkConnection(toGet(csrWriteRespSyncFifo), fakeXdmaA.barWriteClt.response, clocked_by dmacClock, reset_by dmacReset); 


// `define __LOOP_WITH_DELAY_QUEUE True;

`ifdef __LOOP_WITH_DELAY_QUEUE

        FIFOF#(RqDataStreamWithExtraInfo) delayQ <- mkSizedFIFOF(8192);
        // loop tx stream to rx stream with delayed time so they won't interfere eachother.
        rule bufferTxStream;
            
            let data = topA.sqRdmaDataStreamPipeOut.first;
            topA.sqRdmaDataStreamPipeOut.deq;
            let isRawPkt = topA.sqUdpInfoPipeOut.first.isRawPkt;
            let outData = tuple3(data, isRawPkt, 0);
            delayQ.enq(outData);

            if (data.isLast) begin
                topA.sqUdpInfoPipeOut.deq;
            end
            $display("time=%0t: ", $time,"udp put to delayQ = ", fshow(outData));
        endrule

        rule outputTxStream;
            let t <- $time;
            if (t > 17890) begin
                let d = delayQ.first;
                delayQ.deq;
                topA.rqInputDataStream.put(d);
                $display("time=%0t: ", $time, "delayQ put to rqWrapper");
            end
        endrule
`else
        // loop tx stream to rx stream
        rule displayAndForwardWireData;
            let data = topA.sqRdmaDataStreamPipeOut.first;
            topA.sqRdmaDataStreamPipeOut.deq;
            let isRawPkt = topA.sqUdpInfoPipeOut.first.isRawPkt;
            let outData = tuple3(data, isRawPkt, 0);

            if (data.isLast) begin
                topA.sqUdpInfoPipeOut.deq;
            end

            topA.rqInputDataStream.put(outData);
            $display("time=%0t: ", $time, "relay stream from tx to rx: ", fshow(outData));
        endrule
`endif



    rule forwardBarReadReq;
        csrReadReqSyncFifo.deq;
        let inReq = csrReadReqSyncFifo.first;
        let outReq = CsrReadRequest{addr: inReq};
        topA.csrReadSrv.request.put(outReq);
        // $display("csr read req =", fshow(outReq));
    endrule

    rule forwardBarReadResp;
        let inResp <- topA.csrReadSrv.response.get;
        let outResp = inResp.data;
        csrReadRespSyncFifo.enq(outResp);
        // $display("csr read resp =", fshow(outResp));
    endrule

    rule forwardBarWriteReq;
        csrWriteReqSyncFifo.deq;
        let inReq = csrWriteReqSyncFifo.first;
        let outReq = CsrWriteRequest{addr: tpl_1(inReq), data: tpl_2(inReq)};
        topA.csrWriteSrv.request.put(outReq);
        // $display("csr write req = ", fshow(outReq));
    endrule

    rule forwardBarWriteResp;
        let inResp <- topA.csrWriteSrv.response.get;
        let outResp = True;
        csrWriteRespSyncFifo.enq(outResp);
    endrule

endmodule


(* doc = "testcase" *)
module mkTestInjectStreamToCmacControllerWrapper(Empty);
    Clock clk <- mkAbsoluteClock(0, 10);
    Reset r <- mkInitialReset (2, clocked_by clk);
    let dut <- mkTestInjectStreamToCmacController(clocked_by clk, reset_by r);

endmodule

module mkTestInjectStreamToCmacController(Empty);
    Clock rdmaClock <- exposeCurrentClock;
    Reset rdmaReset <- exposeCurrentReset;

    Clock dmacClock <- exposeCurrentClock;
    Reset dmacReset <- exposeCurrentReset;

    Clock udpClock <- exposeCurrentClock;
    Reset udpReset <- exposeCurrentReset;

    Clock cmacRxTxClk <- mkAbsoluteClock(0, 7);  // about 322 MHz
    // Clock cmacRxTxClk <- mkAbsoluteClock(0, 10);
    Reset cmacRxTxRst <- mkSyncReset(2, udpReset, cmacRxTxClk);

    let topA <- mkBsvTop(cmacRxTxClk, cmacRxTxRst, cmacRxTxRst, cmacRxTxClk, cmacRxTxRst);

    Reg#(Bit#(5)) cntReg <- mkReg(0, clocked_by cmacRxTxClk, reset_by cmacRxTxRst);

    Reg#(Bit#(20)) resetCnt <- mkReg(0, clocked_by cmacRxTxClk, reset_by cmacRxTxRst);

    let streamIfc = topA.cmacController.cmacRxController.rxRawAxiStreamIn;



    rule dealWithAlwaysEnable1;
        let regBlockIfc = topA.axilRegBlock;
        regBlockIfc.rdSlave.arValidData(unpack(0),unpack(0),unpack(0));
        regBlockIfc.rdSlave.rReady(unpack(0));
        regBlockIfc.wrSlave.awValidData(unpack(0),unpack(0),unpack(0));
        regBlockIfc.wrSlave.bReady(unpack(0));
        regBlockIfc.wrSlave.wValidData(unpack(0),unpack(0),unpack(0)); 

        topA.xdmaChannel.c2hDescByp.descDone(unpack(0));
        topA.xdmaChannel.c2hDescByp.ready(unpack(0));
        topA.xdmaChannel.h2cDescByp.descDone(unpack(0));
        topA.xdmaChannel.h2cDescByp.ready(unpack(0));
        topA.xdmaChannel.rawC2hAxiStream.tReady(unpack(0));
        topA.xdmaChannel.rawH2cAxiStream.tValid(unpack(0),unpack(0),unpack(0),unpack(0),unpack(0));
    endrule

    rule dealWithAlwaysEnable2;
        topA.cmacController.cmacRxController.cmacRxStatus(True, unpack(0));
        topA.cmacController.cmacTxController.cmacTxStatus(False, False, True);
        topA.cmacController.cmacTxController.rawCmacAxiStreamOut.tReady(True);
    endrule

    rule cnt;
        if (resetCnt < 1024) begin
            resetCnt <= resetCnt + 1;
        end
    endrule

    rule injectdata;

        let data = case (cntReg)
            'h00: 'h4001000060a7127f000000000000020000000000000600002804b712b7120300007f0200007fab781140000001003c0400450008feeeddccbbaaffeeddccbbaa;
            'h01: 'h393837363534333231302f2e2d2c2b2a292827262524232221201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100000001001a25;
            'h02: 'h797877767574737271706f6e6d6c6b6a696867666564636261605f5e5d5c5b5a595857565554535251504f4e4d4c4b4a494847464544434241403f3e3d3c3b3a;
            'h03: 'hb9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4a3a2a1a09f9e9d9c9b9a999897969594939291908f8e8d8c8b8a898887868584838281807f7e7d7c7b7a;
            'h04: 'hf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1d0cfcecdcccbcac9c8c7c6c5c4c3c2c1c0bfbebdbcbbba;
            'h05: 'h393837363534333231302f2e2d2c2b2a292827262524232221201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100fffefdfcfbfa;
            'h06: 'h797877767574737271706f6e6d6c6b6a696867666564636261605f5e5d5c5b5a595857565554535251504f4e4d4c4b4a494847464544434241403f3e3d3c3b3a;
            'h07: 'hb9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4a3a2a1a09f9e9d9c9b9a999897969594939291908f8e8d8c8b8a898887868584838281807f7e7d7c7b7a;
            'h08: 'hf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1d0cfcecdcccbcac9c8c7c6c5c4c3c2c1c0bfbebdbcbbba;
            'h09: 'h393837363534333231302f2e2d2c2b2a292827262524232221201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100fffefdfcfbfa;
            'h0A: 'h797877767574737271706f6e6d6c6b6a696867666564636261605f5e5d5c5b5a595857565554535251504f4e4d4c4b4a494847464544434241403f3e3d3c3b3a;
            'h0B: 'hb9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4a3a2a1a09f9e9d9c9b9a999897969594939291908f8e8d8c8b8a898887868584838281807f7e7d7c7b7a;
            'h0C: 'hf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1d0cfcecdcccbcac9c8c7c6c5c4c3c2c1c0bfbebdbcbbba;
            'h0D: 'h393837363534333231302f2e2d2c2b2a292827262524232221201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100fffefdfcfbfa;
            'h0E: 'h797877767574737271706f6e6d6c6b6a696867666564636261605f5e5d5c5b5a595857565554535251504f4e4d4c4b4a494847464544434241403f3e3d3c3b3a;
            'h0F: 'hb9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4a3a2a1a09f9e9d9c9b9a999897969594939291908f8e8d8c8b8a898887868584838281807f7e7d7c7b7a;
            'h10: 'hf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1d0cfcecdcccbcac9c8c7c6c5c4c3c2c1c0bfbebdbcbbba;
            'h11: 'h00000000000000000000636e41d94f9d0eabfffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e20000636e41d94f9d0eabfffefdfcfbfa;
        endcase;
        
        let byteEn = cntReg == 'h11 ? 'h3FFF: -1;

        let tLast = cntReg == 'h11;

        let canHandshake = resetCnt == 1024 && streamIfc.tReady;

        if (canHandshake) begin
            if (!tLast) begin
                cntReg <= cntReg + 1;
            end 
            else begin
                cntReg <= 0;
            end
        end

        streamIfc.tValid(canHandshake, data, byteEn, tLast, 0);
        
    endrule
    

endmodule