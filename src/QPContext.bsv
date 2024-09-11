import ClientServer :: *;
import BRAM :: *;
import FIFOF :: *;

import DataTypes :: *;
import RdmaUtils :: *;
import Headers :: *;

import Vector :: *;

import Settings :: *;
import MetaData :: *;
import PrimUtils :: *;



interface QPContext;
    interface Server#(ReadReqCommonQPC, Maybe#(EntryCommonQPC)) readCommonSrv;
    interface Server#(WriteReqCommonQPC, Bool) writeCommonSrv;
endinterface

(* synthesize *)
module mkQPContext(QPContext);
    BypassServer#(ReadReqCommonQPC, Maybe#(EntryCommonQPC)) readCommonSrvInst <- mkBypassServer("readCommonSrvInst");
    BypassServer#(WriteReqCommonQPC, Bool) writeCommonSrvInst <- mkBypassServer("writeCommonSrvInst");

    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(IndexQP, Maybe#(EntryCommonQPC)) qpcEntryCommonStorage <- mkBRAM2Server(cfg);

    FIFOF#(KeyQP) keyPipeQ <- mkFIFOF;

    rule handleReadReq;
        let req <- readCommonSrvInst.getReq;
        IndexQP idx = getIndexQP(req.qpn);
        KeyQP key   = getKeyQP(req.qpn);
        let bramReq = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: idx,
            datain: tagged Invalid
        };
        qpcEntryCommonStorage.portA.request.put(bramReq);
        keyPipeQ.enq(key);
        $display("read BRAM idx=", fshow(idx), "req=", fshow(req));
    endrule

    rule handleReadResp;
        let respMaybe <- qpcEntryCommonStorage.portA.response.get;
        let key = keyPipeQ.first;
        keyPipeQ.deq;

        if (respMaybe matches tagged Valid .resp &&& resp.qpnKeyPart == key) begin
            readCommonSrvInst.putResp(tagged Valid resp);
        end 
        else begin
            readCommonSrvInst.putResp(tagged Invalid);
        end
    endrule

    rule handleWriteReq;
        let req <- writeCommonSrvInst.getReq;
        IndexQP idx = getIndexQP(req.qpn);

        let bramReq = BRAMRequest{
            write: True,
            responseOnWrite: True,
            address: idx,
            datain: req.ent
        };
        qpcEntryCommonStorage.portB.request.put(bramReq);
        $display("write BRAM idx=", fshow(idx), "req=", fshow(req.ent));
    endrule

    rule handleWriteResp;
        let resp <- qpcEntryCommonStorage.portB.response.get;
        writeCommonSrvInst.putResp(True);
    endrule

    interface readCommonSrv = readCommonSrvInst.srv;
    interface writeCommonSrv = writeCommonSrvInst.srv;
endmodule

interface ExpectedPsnManager;
    method Action resetPSN(IndexQP qpnIdx);
    method Action submitQpReturnToNormalStateRequest(IndexQP qpnIdx, PSN recoveryPointPSN);

    interface Server#(ExpectedPsnCheckReq, ExpectedPsnCheckResp) psnContextQuerySrv;
endinterface

typedef 4 PSN_CONTINOUS_CHECK_CACHE_SIZE;

module mkExpectedPsnManager(ExpectedPsnManager);

    
    FIFOF#(ExpectedPsnCheckReq) psnQueryKeepOrderQ <- mkFIFOF;

    Vector#(MAX_QP, Reg#(Maybe#(PSN)))   qpReturnToNormalStateReqRegVec <- replicateM(mkReg(tagged Invalid));

    BypassServer#(ExpectedPsnCheckReq, ExpectedPsnCheckResp) psnContextQuerySrvInst <- mkBypassServer("psnContextQuerySrvInst");
    
    RWire#(Tuple2#(IndexQP, ExpectedPsnContextEntry))  updatePsnReqWire <- mkRWire;
    RWire#(IndexQP)                                     resetPsnReqWire <- mkRWire;

    RWire#(Tuple2#(IndexQP, PSN))  submitRecoveryReqWire <- mkRWire;
    RWire#(IndexQP)             getRecoveryPsnNotifyWire <- mkRWire;
    Wire#(BRAMRequest#(IndexQP, ExpectedPsnContextEntry))            psnStorageWriteReqWire <- mkWire;

    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(IndexQP, ExpectedPsnContextEntry) psnStorage <- mkBRAM2Server(cfg);

    PrioritySearchBuffer#(PSN_CONTINOUS_CHECK_CACHE_SIZE, IndexQP, ExpectedPsnContextEntry) psnCache <- mkPrioritySearchBuffer(valueOf(PSN_CONTINOUS_CHECK_CACHE_SIZE));

    rule handlePsnQueryReq;
        let req <- psnContextQuerySrvInst.getReq;
        let qpIdx = req.qpnIdx;
        let bramReq = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: qpIdx,
            datain: ?
        };

        psnStorage.portA.request.put(bramReq);
        psnQueryKeepOrderQ.enq(req);
    endrule

    rule handlePsnQueryResp;
        let bramResp <- psnStorage.portA.response.get;
        let req = psnQueryKeepOrderQ.first;
        psnQueryKeepOrderQ.deq;

        let cacheRespMaybe <- psnCache.search(req.qpnIdx);

        let storedIsQpPsnContinous = bramResp.isQpPsnContinous;
        let storedLatestErrorPSN = bramResp.latestErrorPSN;
        let storedExpectedPSN    = bramResp.expectedPSN;       
        
        $display("time=%0t:", $time, " storedExpectedPSN=", fshow(storedExpectedPSN));

        if (cacheRespMaybe matches tagged Valid .cacheResp) begin
            storedIsQpPsnContinous = cacheResp.isQpPsnContinous;
            storedLatestErrorPSN = cacheResp.latestErrorPSN;
            storedExpectedPSN    = cacheResp.expectedPSN;  
            $display("time=%0t:", $time, " upadte storedExpectedPSN to cached value, value=", fshow(storedExpectedPSN)); 
        end

        let newIsQpPsnContinous = storedIsQpPsnContinous;
        let newLatestErrorPSN = storedLatestErrorPSN;
        let newExpectedPSN    = storedExpectedPSN;

        let newErrorOccured   = False;

        // Since the max outstanding packet number is MAX_PSN / 2
        // if the minus result is smaller than MAX_PSN / 2, it menas (req.newIncomingPSN > storedExpectedPSN)
        let isCurPsnGreaterOrEqualThanExpectedPSN = msb(req.newIncomingPSN - storedExpectedPSN) == 1'b0;

        let isAdjacentPsnContinous = False;
        if (req.isPacketStateAbnormal) begin
            newIsQpPsnContinous = False;
            newLatestErrorPSN = req.newIncomingPSN;
            newErrorOccured   = True;
        end 
        else if (isCurPsnGreaterOrEqualThanExpectedPSN) begin
            // expected PSN is monotone increasing
            newExpectedPSN = req.newIncomingPSN + 1;
            isAdjacentPsnContinous = req.newIncomingPSN == storedExpectedPSN;
            if (!isAdjacentPsnContinous) begin
                // if not equal, it must be greater than expected, so change to non-continous state
                // if we receive a psn less than expected PSN, it's a out-of-order packet or retry packet,
                // so we should not modify newIsQpPsnContinous. E.g., if we are in normal state and receive 
                // a retry packet, we should ignore it and not turn into non-continous state.
                newIsQpPsnContinous = False;
                newLatestErrorPSN = req.newIncomingPSN;
                newErrorOccured   = True;
            end
        end

        // handle recovery logic
        if (qpReturnToNormalStateReqRegVec[req.qpnIdx] matches tagged Valid .recoveryPSN) begin
            if (recoveryPSN == newLatestErrorPSN && !newErrorOccured) begin
                newIsQpPsnContinous = True;
            end
            getRecoveryPsnNotifyWire.wset(req.qpnIdx);
        end

        let bramNewValue = ExpectedPsnContextEntry {
            expectedPSN:    newExpectedPSN,
            latestErrorPSN: newLatestErrorPSN,
            isQpPsnContinous: newIsQpPsnContinous
        };

        updatePsnReqWire.wset(tuple2(req.qpnIdx, bramNewValue));

        let resp = ExpectedPsnCheckResp {
            expectedPSN: storedExpectedPSN,
            isQpPsnContinous: newIsQpPsnContinous,
            isAdjacentPsnContinous: isAdjacentPsnContinous
        };
        psnContextQuerySrvInst.putResp(resp);
    endrule

    (* fire_when_enabled, no_implicit_conditions *)
    rule canonicalize;
        if (resetPsnReqWire.wget matches tagged Valid .qpnIdx) begin
            let bramNewValue = ExpectedPsnContextEntry {
                expectedPSN : 0,
                latestErrorPSN : 0,
                isQpPsnContinous : True
            };

            let bramReq = BRAMRequest{
                write: True,
                responseOnWrite: False,
                address: qpnIdx,
                datain: bramNewValue
            };
            psnCache.enq(qpnIdx, bramNewValue);
            psnStorageWriteReqWire <= bramReq;
        end
        else if (updatePsnReqWire.wget matches tagged Valid .req) begin
            let {qpnIdx, bramNewValue} = req;
            let bramReq = BRAMRequest{
                write: True,
                responseOnWrite: False,
                address: qpnIdx,
                datain: bramNewValue
            };
            psnCache.enq(qpnIdx, bramNewValue);
            psnStorageWriteReqWire <= bramReq;
        end

        case ({pack(isValid(getRecoveryPsnNotifyWire.wget)), pack(isValid(submitRecoveryReqWire.wget))})
            2'b00: begin
                // Do nothing
            end
            2'b01,
            2'b11: begin
                let {qpnSubmit, psn} = fromMaybe(?, submitRecoveryReqWire.wget);
                qpReturnToNormalStateReqRegVec[qpnSubmit] <= tagged Valid psn;
            end
            2'b10: begin
                let qpnGet = fromMaybe(?, getRecoveryPsnNotifyWire.wget);
                qpReturnToNormalStateReqRegVec[qpnGet] <= tagged Invalid;
            end 
        endcase
    endrule

    rule doPsnStorageWrite;
        psnStorage.portB.request.put(psnStorageWriteReqWire);
    endrule

    method Action submitQpReturnToNormalStateRequest(IndexQP qpnIdx, PSN recoveryPointPSN);
        submitRecoveryReqWire.wset(tuple2(qpnIdx, recoveryPointPSN));
    endmethod

    method Action resetPSN(IndexQP qpnIdx);
        resetPsnReqWire.wset(qpnIdx);
    endmethod

    interface psnContextQuerySrv = psnContextQuerySrvInst.srv;

endmodule

interface PrioritySearchBuffer#(numeric type depth, type t_tag, type t_val);
    method Action enq(t_tag tag, t_val value);
    method ActionValue#(Maybe#(t_val)) search(t_tag tag);
endinterface

// A fifo like buffer, if buffer is full, new enq will lead to deq of the oldest element.
// if the same tags exist in the buffer, the newest enququed element will be returned.
module mkPrioritySearchBuffer#(numeric depth)(PrioritySearchBuffer#(depth, t_tag, t_val)) provisos (
    Bits#(t_tag, sz_tag),
    Bits#(t_val, sz_val),
    Eq#(t_tag),
    FShow#(t_tag),
    FShow#(t_val),
    FShow#(Tuple2#(t_tag, t_val))
);
    Vector#(depth, Reg#(Maybe#(Tuple2#(t_tag, t_val)))) bufferVec <- replicateM(mkReg(tagged Invalid));

    method Action enq(t_tag tag, t_val value);
        for (Integer idx=0; idx < valueOf(depth)-1; idx=idx+1) begin
            bufferVec[idx+1] <= bufferVec[idx];
        end
        bufferVec[0] <= tagged Valid tuple2(tag, value);
        $display("time=%0t:", $time, " psn cache enqueue, tag=", fshow(tag));
    endmethod

    method ActionValue#(Maybe#(t_val)) search(t_tag tag);
        Maybe#(t_val) ret = tagged Invalid;
        for (Integer idx=valueOf(depth)-1; idx >=0 ; idx=idx-1) begin
            $display("time=%0t:", $time, " psn cache slot %d", idx, "bufferVec[idx]=", fshow(bufferVec[idx]));
            if (bufferVec[idx] matches tagged Valid .readTuple) begin
                let {readTag, readVal} = readTuple;
                if (readTag == tag) begin
                    ret = tagged Valid readVal;
                    $display("time=%0t:", $time, " psn cache hit slot %d", idx, "ret=", fshow(ret));
                end
            end
        end
        return ret;
    endmethod
endmodule