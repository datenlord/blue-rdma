import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;
import Cntrs :: * ;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import RdmaUtils :: *;
import UserLogicTypes :: *;
import UserLogicUtils :: *;
import MetaData :: *;



typedef Server#(addrType, dataType)                    BramRead#(type addrType, type dataType);
typedef Server#(Tuple2#(addrType, dataType), Bool)     BramWrite#(type addrType, type dataType);

interface BramCache#(type addrType, type dataType, numeric type splitCntExp);
    interface BramRead #(addrType, dataType)   read;
    interface BramWrite#(addrType, dataType)   write;
endinterface


module mkBramCache(BramCache#(addrType, dataType, splitCntExp)) provisos(
    Bits#(addrType, addrTypeSize),
    Bits#(dataType, dataTypeSize),
    Add#(subAddrTypeSize, splitCntExp, addrTypeSize),
    Alias#(Bit#(subAddrTypeSize), subAddrType),
    Alias#(Bit#(splitCntExp), subBlockIdxType),
    FShow#(addrType),
    FShow#(dataType)
);
    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;

    Vector#(TExp#(splitCntExp), BRAM2Port#(subAddrType, dataType)) subBramVec <- replicateM(mkBRAM2Server(cfg));
    // Vector#(TExp#(splitCntExp), FIFOF#(BRAMRequest#(subAddrType, dataType))) subReqFifoVecPortA <- replicateM(mkFIFOF);
    // Vector#(TExp#(splitCntExp), FIFOF#(BRAMRequest#(subAddrType, dataType))) subReqFifoVecPortB <- replicateM(mkFIFOF);

    FIFOF#(subBlockIdxType) orderKeepQueuePortA <- mkSizedFIFOF(6);
    FIFOF#(subBlockIdxType) orderKeepQueuePortB <- mkSizedFIFOF(6);

    // for (Integer idx = 0; idx < valueOf(TExp#(splitCntExp)); idx = idx + 1) begin
    //     rule forwardPortAReq;
    //         let req = subReqFifoVecPortA[idx].first;
    //         subReqFifoVecPortA[idx].deq;
    //         subBramVec[idx].portA.request.put(req);
    //     endrule

    //     rule forwardPortBReq;
    //         let req = subReqFifoVecPortB[idx].first;
    //         subReqFifoVecPortB[idx].deq;
    //         subBramVec[idx].portB.request.put(req);
    //     endrule
    // end

    BRAM2Port#(addrType, dataType) bram2Port <- mkBRAM2Server(cfg);

    FIFOF#(addrType)   bramReadReqQ <- mkFIFOF;
    FIFOF#(dataType)  bramReadRespQ <- mkFIFOF;

    FIFOF#(Tuple2#(addrType, dataType))  bramWriteReqQ  <- mkFIFOF;
    FIFOF#(Bool)                         bramWriteRespQ <- mkFIFOF;

    rule handleBramReadReq;
        let cacheAddr = bramReadReqQ.first;
        bramReadReqQ.deq;

        subAddrType addr = unpack(truncate(pack(cacheAddr)));
        let req = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: addr,
            datain: dontCareValue
        };
        subBlockIdxType subIdx = truncateLSB(pack(cacheAddr));
        // subReqFifoVecPortA[subIdx].enq(req);
        subBramVec[subIdx].portA.request.put(req);
        orderKeepQueuePortA.enq(subIdx);
        // $display("send BRAM read req to sub block =", fshow(subIdx), "addr=", fshow(addr));
    endrule

    rule handleBramReadResp;
        let subIdx = orderKeepQueuePortA.first;
        orderKeepQueuePortA.deq;
        let readRespData <- subBramVec[subIdx].portA.response.get;
        bramReadRespQ.enq(readRespData);
        // $display("recv BRAM read resp from sub block=", fshow(subIdx) , ", res=", fshow(readRespData));
    endrule


    rule handleBramWriteReq;
        let {cacheAddr, writeData} = bramWriteReqQ.first;
        bramWriteReqQ.deq;
        
        subAddrType addr = unpack(truncate(pack(cacheAddr)));
        let req = BRAMRequest{
            write: True,
            responseOnWrite: True,
            address: addr,
            datain: writeData
        };
        subBlockIdxType subIdx = truncateLSB(pack(cacheAddr));
        // subReqFifoVecPortB[subIdx].enq(req);
        subBramVec[subIdx].portB.request.put(req);
        orderKeepQueuePortB.enq(subIdx);
        // $display("send BRAM write req to sub block =", fshow(subIdx), "addr=", fshow(addr));
    endrule

    rule handleBramWriteResp;
        let subIdx = orderKeepQueuePortB.first;
        orderKeepQueuePortB.deq;
        let _ <- subBramVec[subIdx].portB.response.get;
        bramWriteRespQ.enq(True);
        // $display("recv BRAM write resp from sub block =", fshow(subIdx));
    endrule


    interface read =  toGPServer(bramReadReqQ,  bramReadRespQ);
    interface write = toGPServer(bramWriteReqQ, bramWriteRespQ);
endmodule


interface MemRegionTable;
    interface Server#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) querySrv;
    interface Server#(MrTableModifyReq, MrTableModifyResp) modifySrv;
endinterface

(* synthesize *)
module mkMemRegionTable(MemRegionTable);
    BramCache#(IndexMR, Maybe#(MemRegionTableEntry), 0) mrTableStorage <- mkBramCache;
    BypassServer#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) querySrvInst <- mkBypassServer("mkMemRegionTable querySrvInst");
    BypassServer#(MrTableModifyReq, MrTableModifyResp) modifySrvInst <- mkBypassServer("modifySrvInst");

    rule handleQueryReq;
        let req <- querySrvInst.getReq;
        mrTableStorage.read.request.put(req.idx);
        $display("get MrTable query req: ", fshow(req));
    endrule

    rule handleQueryResp;
        let resp <- mrTableStorage.read.response.get;
        querySrvInst.putResp(resp);
        $display("send MrTable query resp: ", fshow(resp));
    endrule

    rule handleModifyReq;
        let req <- modifySrvInst.getReq;
        mrTableStorage.write.request.put(tuple2(req.idx, req.entry));
        $display("get MrTable update req: ", fshow(req));
    endrule

    rule handleModifyResp;
        let resp <- mrTableStorage.write.response.get;
        modifySrvInst.putResp(MrTableModifyResp{success: resp});
    endrule

    interface querySrv = querySrvInst.srv;
    interface modifySrv = modifySrvInst.srv;
endmodule


interface TLB;
    interface Server#(PgtAddrTranslateReq, ADDR) translateSrv;
    interface Server#(PgtModifyReq, PgtModifyResp) modifySrv;
endinterface

function PageOffset getPageOffset(ADDR addr);
    return truncate(addr);
endfunction

function ADDR restorePA(PageNumber pn, PageOffset po);
    return signExtend({ pn, po });
endfunction

function PageNumber getPageNumber(ADDR pa);
    return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
endfunction

(* synthesize *)
module mkTLB(TLB);
    
    BramCache#(PTEIndex, PageTableEntry, 2) pageTableStorage <- mkBramCache;

    BypassServer#(PgtAddrTranslateReq, ADDR) translateSrvInst <- mkBypassServer("translateSrvInst");
    BypassServer#(PgtModifyReq, PgtModifyResp) modifySrvInst <- mkBypassServer("modifySrvInst");

    FIFOF#(Bit#(PAGE_OFFSET_WIDTH)) offsetInputQ <- mkSizedFIFOF(10);

    rule handleTranslateReq;
        let req <- translateSrvInst.getReq;
        let mr = req.mrEntry;
        let va = req.addrToTrans;

        let pageNumberOffset = getPageNumber(va) - getPageNumber(mr.baseVA);
        PTEIndex pteIdx = mr.pgtOffset + truncate(pageNumberOffset);
        pageTableStorage.read.request.put(pteIdx);

        offsetInputQ.enq(getPageOffset(va));

        $display("query TLB req = ", fshow(req), "pte index=", fshow(pteIdx));
    endrule

    rule handleTranslateResp;
        let pageOffset = offsetInputQ.first;
        offsetInputQ.deq;

        PageTableEntry pte <- pageTableStorage.read.response.get;

        let pa = restorePA(pte.pn, pageOffset);
        translateSrvInst.putResp(pa);

        $display("query TLB resp pageOffset= ", fshow(pageOffset), "pte =", fshow(pte));
        
    endrule

    rule handleModifyReq;
        let req <- modifySrvInst.getReq;
        pageTableStorage.write.request.put(tuple2(req.idx, req.pte));
        $display("insert TLB = ", fshow(req));
    endrule

    rule handleModifyResp;
        let resp <- pageTableStorage.write.response.get;
        modifySrvInst.putResp(PgtModifyResp{success: resp});
    endrule


    interface translateSrv = translateSrvInst.srv;
    interface modifySrv = modifySrvInst.srv;
endmodule



interface MrAndPgtManager;
    interface Server#(RingbufRawDescriptor, Bool) mrAndPgtModifyDescSrv;
    interface UserLogicDmaReadClt pgtDmaReadClt;
    interface Client#(MrTableModifyReq, MrTableModifyResp) mrModifyClt;
    interface Client#(PgtModifyReq, PgtModifyResp) pgtModifyClt;
endinterface


typedef enum {
    MrAndPgtManagerFsmStateIdle,
    MrAndPgtManagerFsmStateWaitMRModifyResponse,
    MrAndPgtManagerFsmStateHandlePGTUpdate,
    MrAndPgtManagerFsmStateWaitPGTUpdateLastResp
} MrAndPgtManagerFsmState deriving(Bits, Eq);


(* synthesize *)
module mkMrAndPgtManager(MrAndPgtManager);
    FIFOF#(RingbufRawDescriptor) reqQ <- mkFIFOF;
    FIFOF#(Bool) respQ <- mkFIFOF;

    FIFOF#(UserLogicDmaH2cReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cResp) dmaReadRespQ <- mkFIFOF;

    BypassClient#(MrTableModifyReq, MrTableModifyResp) mrModifyCltInst <- mkBypassClient("mrModifyCltInst");
    BypassClient#(PgtModifyReq, PgtModifyResp) pgtModifyCltInst <- mkBypassClient("pgtModifyCltInst");
    

    Reg#(MrAndPgtManagerFsmState) state <- mkReg(MrAndPgtManagerFsmStateIdle);

    Reg#(DataStream) curBeatOfDataReg <- mkReg(unpack(0));
    Reg#(PTEIndex) curSecondStagePgtWriteIdxReg <- mkRegU;
    
    Integer bytesPerPgtSecondStageEntryRequest = valueOf(PGT_SECOND_STAGE_ENTRY_REQUEST_SIZE_PADDED) / valueOf(BYTE_WIDTH);

    // we set max inflight pgt update request is 2^3 = 8;
    Count#(Bit#(3)) pgtUpdateRespCounter <- mkCount(0);

    rule updateMrAndPgtStateIdle if (state == MrAndPgtManagerFsmStateIdle);
        let descRaw = reqQ.first;
        reqQ.deq;
        // $display("PGT get modify request", fshow(descRaw));
        let opcode = getCmdQueueOpcodeFromRawRingbufDescriptor(descRaw);

        case (unpack(truncate(opcode)))
            CmdQueueOpcodeUpdateMrTable: begin
                state <= MrAndPgtManagerFsmStateWaitMRModifyResponse;
                CmdQueueReqDescUpdateMrTable desc = unpack(descRaw);
                let modifyReq = MrTableModifyReq {
                    idx: key2IndexMR(desc.mrKey),
                    entry: isZeroR(desc.mrLength) ?
                            tagged Invalid : 
                            tagged Valid MemRegionTableEntry {
                                pgtOffset: desc.pgtOffset,
                                baseVA: desc.mrBaseVA,
                                len: desc.mrLength,
                                accFlags: unpack(desc.accFlags),
                                pdHandler: desc.pdHandler,
                                keyPart: lkey2KeyPartMR(desc.mrKey)
                            }
                };
                mrModifyCltInst.putReq(modifyReq);
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(desc));
            end
            CmdQueueOpcodeUpdatePGT: begin
                CmdQueueReqDescUpdatePGT desc = unpack(descRaw);
                immAssertAddressAlign(desc.dmaAddr, AddressAlignAssertionMask4KB, "PGT table update dma request");
                dmaReadReqQ.enq(UserLogicDmaH2cReq{
                    addr: desc.dmaAddr,
                    len: truncate(desc.dmaReadLength)
                });
                curSecondStagePgtWriteIdxReg <= truncate(desc.startIndex);
                state <= MrAndPgtManagerFsmStateHandlePGTUpdate;
                $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "Hardware receive cmd queue descriptor: ", fshow(desc));
            end
        endcase
    endrule

    rule handleMrModifyResp if (state == MrAndPgtManagerFsmStateWaitMRModifyResponse);
        let _ <- mrModifyCltInst.getResp;
        respQ.enq(True);
        state <= MrAndPgtManagerFsmStateIdle;
    endrule


    rule updatePgtStateHandlePGTUpdate if (state == MrAndPgtManagerFsmStateHandlePGTUpdate);
        // since this is the control path, it's not fully pipelined to make it simple.
        if (isZeroR(curBeatOfDataReg.byteNum)) begin
            if (curBeatOfDataReg.isLast) begin
                state <= MrAndPgtManagerFsmStateWaitPGTUpdateLastResp;
                curBeatOfDataReg <= unpack(0);
                $display("addr translate modify second stage finished.");
            end 
            else begin
                // the data should be right aligned, but to convert byteEn to byteNum, byteEn need to be left aligned
                let newFrag = dataStreamEnLeftAlign2DataStream(reverseStreamEnOnly(dmaReadRespQ.first.dataStream));
                curBeatOfDataReg <= newFrag;
                $display("receive dma batch page table frag=", fshow(newFrag));
                dmaReadRespQ.deq;
            end
        end 
        else begin 
            let modifyReq = PgtModifyReq{
                idx: curSecondStagePgtWriteIdxReg,
                pte: PageTableEntry {
                    pn: truncate(curBeatOfDataReg.data >> valueOf(PAGE_OFFSET_WIDTH))
                }
            };
            pgtModifyCltInst.putReq(modifyReq);
            pgtUpdateRespCounter.incr(1);
            $display("addr translate modify second stage:", fshow(modifyReq));
            curSecondStagePgtWriteIdxReg <= curSecondStagePgtWriteIdxReg + 1;
            let t = curBeatOfDataReg;
            t.byteNum = t.byteNum - fromInteger(bytesPerPgtSecondStageEntryRequest);
            t.data = t.data >> valueOf(PGT_SECOND_STAGE_ENTRY_REQUEST_SIZE_PADDED);
            curBeatOfDataReg <= t;
        end
    endrule

    rule handlePgtModifyResp;
        let _ <- pgtModifyCltInst.getResp;
        pgtUpdateRespCounter.decr(1);
    endrule

    rule handlePgtModifyLastResp if (state == MrAndPgtManagerFsmStateWaitPGTUpdateLastResp);
        if (pgtUpdateRespCounter == 0) begin
            respQ.enq(True);
            state <= MrAndPgtManagerFsmStateIdle;
        end
    endrule

    interface mrAndPgtModifyDescSrv = toGPServer(reqQ, respQ);
    interface pgtDmaReadClt = toGPClient(dmaReadReqQ, dmaReadRespQ);
    interface mrModifyClt = mrModifyCltInst.clt;
    interface pgtModifyClt = pgtModifyCltInst.clt;
endmodule


interface DmaReqAddrTranslator;
    interface Server#(DmaReadReq, DmaReadResp) sqReqInputSrv;
    interface Client#(UserLogicDmaH2cReq, UserLogicDmaH2cResp) sqReqOutputClt;

    interface MrTableQueryClt mrTableClt;
    interface PgtQueryClt addrTransClt;    
endinterface



(* synthesize *)
module mkDmaReadReqAddrTranslator(DmaReqAddrTranslator);
    FIFOF#(DmaReadReq) readReqInQ <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cReq) readReqOutQ <- mkFIFOF;
    FIFOF#(UserLogicDmaH2cResp) readRespInQ <- mkFIFOF;
    FIFOF#(DmaReadResp) readRespOutQ <- mkFIFOF;

    FIFOF#(DmaReadReq) pendingReqQ <- mkSizedFIFOF(5);
    FIFOF#(ADDR) vaPipelineQ <- mkSizedFIFOF(5);

    BypassClient#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) mrTableQueryCltInst  <- mkSizedBypassClient("mrTableQueryCltInst in mkDmaReadReqAddrTranslator", 5, 2);
    BypassClient#(PgtAddrTranslateReq, ADDR) pgtQueryCltInst                         <- mkBypassClient("SQ pgtQueryCltInst");

    // rule debug;
    //     if (!readReqInQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readReqInQ");
    //     end
    //     if (!readReqOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readReqOutQ");
    //     end
    //     if (!readRespInQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readRespInQ");
    //     end
    //     if (!readRespOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readRespOutQ");
    //     end

    //     if (!pendingReqQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator pendingReqQ");
    //     end
    //     if (!vaPipelineQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkDmaReadReqAddrTranslator vaPipelineQ");
    //     end

    //     if (!readReqOutQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readReqOutQ");
    //     end
    //     if (!readRespOutQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkDmaReadReqAddrTranslator readRespOutQ");
    //     end


    // endrule


    rule handleInputReq;
        readReqInQ.deq;
        let req = readReqInQ.first;
        pendingReqQ.enq(req);
        let mrTableQueryReq = MrTableQueryReq{
            idx: req.mrIdx
        };
        mrTableQueryCltInst.putReq(mrTableQueryReq);
        vaPipelineQ.enq(req.startAddr);
        $display("time=%0t: ", $time, "mkDmaReadReqAddrTranslator, handleInputReq, req=", fshow(req));
    endrule

    rule handleMrRespAndSendPgtReq;
        let maybeMrResp <- mrTableQueryCltInst.getResp;
        let va = vaPipelineQ.first;
        vaPipelineQ.deq;
        
        // Assume that request always success. to simplify SQ logic
        let mrResp = fromMaybe(unpack(0), maybeMrResp);

        let pgtReq = PgtAddrTranslateReq{
            mrEntry: mrResp,
            addrToTrans: va
        };

        pgtQueryCltInst.putReq(pgtReq);
    endrule

    rule handleRespPGTAndSendDmaReq;
        let pa <- pgtQueryCltInst.getResp;
        let originDmaReq = pendingReqQ.first;
        pendingReqQ.deq;

        readReqOutQ.enq(UserLogicDmaH2cReq{
            addr: pa,
            len:  zeroExtend(originDmaReq.len)
        });
        $display("time=%0t: ", $time, "mkDmaReadReqAddrTranslator, handleRespPGTAndSendDmaReq, originDmaReq=", fshow(originDmaReq), "pa=", fshow(pa));
    endrule

    rule forwardResponseDMA;
        let inResp = readRespInQ.first;
        readRespInQ.deq;

        let resp = DmaReadResp{
            isRespErr   : False,
            dataStream  : dataStreamEnLeftAlign2DataStream(reverseStreamEnAndData(inResp.dataStream))
        };
        readRespOutQ.enq(resp);
        $display("time=%0t: ", $time, "mkDmaReadReqAddrTranslator, forwardResponseDMA, resp=", fshow(resp), ", origin resp = ", fshow(inResp));
    endrule



    interface sqReqInputSrv  = toGPServer(readReqInQ, readRespOutQ);
    interface sqReqOutputClt = toGPClient(readReqOutQ, readRespInQ);
    interface mrTableClt     =   mrTableQueryCltInst.clt;
    interface addrTransClt   =   pgtQueryCltInst.clt;
endmodule