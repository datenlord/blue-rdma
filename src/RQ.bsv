import FIFOF :: *;
import GetPut :: *;
import Vector :: *;
import Probe :: *;

import ClientServer :: *;
import RdmaUtils :: *;
import MetaData :: *;
import DataTypes :: *;
import Headers :: *;
import PAClib :: *;
import PrimUtils :: *;
import QPContext :: *;
import PayloadGen :: *;

import UserLogicTypes :: *;

typedef struct {
    RdmaPktMetaDataAndQPC   pktMetaDataAndQpc;
    RdmaReqStatus           reqStatus;
    Bool                    rdmaOpCodeNeedQueryMrTable;
    Bool                    lowerAddrBoundOk;
    ADDR                    mrUpperAddrBound;
    ADDR                    reqUpperAddrBound;
    Bool                    isMrValid;
    Bool                    needWaitForPGTResponse;
    Bool                    isMrKeyMatch;
    Bool                    isAccTypeMatch;
} ReqStatusCheckStep3PipeInfo deriving(Bits, FShow);


interface RQ;
    interface Put#(Tuple3#(IndexQP, PSN, RqPsnManagerPsnUpadteAction)) setRqExpectedPsnReqIn;
    interface Put#(RdmaPktMetaDataAndQPC) pktMetaDataPipeIn;
    interface MrTableQueryClt mrTableQueryClt;
    interface PgtQueryClt pgtQueryClt;
    interface Client#(PayloadConReq, PayloadConResp) payloadConsumerControlPortClt;
    interface PipeOut#(C2hReportEntry) pktReportEntryPipeOut;
    interface PipeOut#(AutoAckGenMetaData)  autoAckMetaPipeOut;
endinterface

(* synthesize *)
module mkRQ(RQ ifc);
    FIFOF#(RdmaPktMetaDataAndQPC)                                    rdmaPktMetaDataInQ <- mkFIFOF;
    FIFOF#(C2hReportEntry)                                              pktReportEntryQ <- mkFIFOF;
    FIFOF#(Tuple3#(IndexQP, PSN, RqPsnManagerPsnUpadteAction))     setRqExpectedPsnReqQ <- mkFIFOF;
    FIFOF#(AutoAckGenMetaData)                                          autoAckGenMetaQ <- mkFIFOF;

    BypassClient#(MrTableQueryReq, Maybe#(MemRegionTableEntry)) mrTableQueryCltInst  <- mkBypassClient("mrTableQueryCltInst in RQ");
    BypassClient#(PgtAddrTranslateReq, ADDR) pgtQueryCltInst                         <- mkBypassClient("RQ pgtQueryCltInst");
    BypassClient#(PayloadConReq, PayloadConResp) payloadConsumerControlClt           <- mkBypassClient("payloadConsumerControlClt");
    
    ExpectedPsnManager expectedPsnManager <- mkExpectedPsnManager;

    // Pipeline FIFOs
    FIFOF#(Tuple2#(RdmaPktMetaDataAndQPC, Bool))                                                             reqStatusCheckStep1PipeQ   <- mkSizedFIFOF(5);
    FIFOF#(Tuple5#(RdmaPktMetaDataAndQPC, RdmaReqStatus, Bool, FlagsType#(MemAccessTypeFlag), RETH))         reqStatusCheckStep2PipeQ   <- mkFIFOF;
    FIFOF#(ReqStatusCheckStep3PipeInfo)                                                                      reqStatusCheckStep3PipeQ   <- mkFIFOF;

    FIFOF#(Tuple4#(RdmaPktMetaDataAndQPC, RdmaReqStatus, Bool, Bool))                                              getPGTQueryRespPipeQ <- mkSizedFIFOF(5);
    FIFOF#(Tuple3#(RdmaPktMetaDataAndQPC, RdmaReqStatus, Bool))                                                 psnContextQueryReqPipeQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaDataAndQPC, RdmaReqStatus, Bool, Bool))                                           psnContinuityCheckPipeQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaDataAndQPC, RdmaReqStatus, PSN, Bool, Bool, Bool))                                waitDMARespPipeQ        <- mkFIFOF;

    Reg#(Bit#(7)) queueFullDebugReg <- mkReg(-1);
    Probe#(Bit#(7)) queueFullDebugProbe <- mkProbe;
    rule debugFillQueueFullDebugReg;
        queueFullDebugReg <= queueFullDebugReg & {
            pack(reqStatusCheckStep1PipeQ.notFull),
            pack(reqStatusCheckStep2PipeQ.notFull),
            pack(reqStatusCheckStep3PipeQ.notFull),
            pack(getPGTQueryRespPipeQ.notFull),
            pack(psnContextQueryReqPipeQ.notFull),
            pack(psnContinuityCheckPipeQ.notFull),
            pack(waitDMARespPipeQ.notFull)
        };
        queueFullDebugProbe <= queueFullDebugReg;
    endrule

    function FlagsType#(MemAccessTypeFlag) genAccessFlagFromReqType(Bool isSend, Bool isRead, Bool isWrite, Bool isAtomic);
        let accFlags = enum2Flag(IBV_ACCESS_LOCAL_WRITE);
        case ({pack(isSend), pack(isRead), pack(isWrite), pack(isAtomic)})
            4'b1000: begin  // Send
                accFlags = enum2Flag(IBV_ACCESS_LOCAL_WRITE);
            end
            4'b0100: begin  // Read
                accFlags = enum2Flag(IBV_ACCESS_REMOTE_READ);
            end
            4'b0010: begin  // Write
                accFlags = enum2Flag(IBV_ACCESS_REMOTE_WRITE);
            end
            4'b0001: begin  // Atomic
                accFlags = enum2Flag(IBV_ACCESS_REMOTE_ATOMIC);
            end
            default: begin end
        endcase
        return accFlags;
    endfunction



    rule debug;
        if (!rdmaPktMetaDataInQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaPktMetaDataInQ");
        end
        if (!pktReportEntryQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: pktReportEntryQ");
        end
        if (!setRqExpectedPsnReqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: setRqExpectedPsnReqQ");
        end
        if (!autoAckGenMetaQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: autoAckGenMetaQ");
        end
        if (!reqStatusCheckStep1PipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: reqStatusCheckStep1PipeQ");
        end
        if (!reqStatusCheckStep2PipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: reqStatusCheckStep2PipeQ");
        end
        if (!reqStatusCheckStep3PipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: reqStatusCheckStep3PipeQ");
        end
        if (!getPGTQueryRespPipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: getPGTQueryRespPipeQ");
        end
        if (!psnContextQueryReqPipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: psnContextQueryReqPipeQ");
        end
        if (!psnContinuityCheckPipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: psnContinuityCheckPipeQ");
        end
        if (!waitDMARespPipeQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: waitDMARespPipeQ");
        end                        
    endrule




    rule queryMemoryRegionTable;
        let pktMetaDataAndQpc = rdmaPktMetaDataInQ.first;
        rdmaPktMetaDataInQ.deq;

        let bth  = extractBTH(pktMetaDataAndQpc.metadata.pktHeader.headerData);
        let reth = extractPriRETH(pktMetaDataAndQpc.metadata.pktHeader.headerData, bth.trans);

        let isRespNeedDMAWrite   = rdmaRespNeedDmaWrite(bth.opcode);
        let isReqNeedDMAWrite    = rdmaReqNeedDmaWrite(bth.opcode);
        let isRawPacket = pktMetaDataAndQpc.metadata.pktHeader.headerMetaData.isEmptyHeader;

        if (isRawPacket) begin
            // for RawPacket, Update RETH len, so we can report packet len to software driver
            reth.dlen = zeroExtend(pktMetaDataAndQpc.metadata.pktPayloadLen);
        end

        let rdmaOpCodeNeedQueryMrTable    = isRespNeedDMAWrite || isReqNeedDMAWrite;

        // only need to query MRTable or PGT if we need DMA access, for packet like ACK/NACK, no need to check
        if (rdmaOpCodeNeedQueryMrTable) begin 
            let mrTableQueryReq = MrTableQueryReq{
                idx: rkey2IndexMR(reth.rkey)
            };
            $display("reth=", fshow(reth), "mrTableQueryReq=", fshow(mrTableQueryReq));
            mrTableQueryCltInst.putReq(mrTableQueryReq);
        end

        reqStatusCheckStep1PipeQ.enq(tuple2(pktMetaDataAndQpc, rdmaOpCodeNeedQueryMrTable));

        $display("time=%0t: ", $time, "queryMemoryRegionTable",
                 ", bth=",  fshow(bth),
                 ", reth=",  fshow(reth),
                 ", pktMetaDataAndQpc=",  fshow(pktMetaDataAndQpc)
        );
        
    endrule

    rule reqStatusCheckStep1;

        let {pktMetaDataAndQpc, rdmaOpCodeNeedQueryMrTable} = reqStatusCheckStep1PipeQ.first;
        reqStatusCheckStep1PipeQ.deq;

        let pktMetaData = pktMetaDataAndQpc.metadata;
        let rdmaHeader  = pktMetaData.pktHeader;
        let qpc = pktMetaDataAndQpc.qpc;
        

        let bth   = extractBTH(rdmaHeader.headerData);
        let reth  = extractPriRETH(rdmaHeader.headerData, bth.trans);

        let isSendReq            = isSendReqRdmaOpCode(bth.opcode);
        let isWriteReq           = isWriteReqRdmaOpCode(bth.opcode);
        let isWriteImmReq        = isWriteImmReqRdmaOpCode(bth.opcode);
        let isReadReq            = isReadReqRdmaOpCode(bth.opcode);
        let isReadResp            = isReadRespRdmaOpCode(bth.opcode);
        let isAtomicReq          = isAtomicReqRdmaOpCode(bth.opcode);
        let isFirstOrOnlyPkt     = isFirstOrOnlyRdmaOpCode(bth.opcode);
        let isLastOrOnlyPkt      = isLastOrOnlyRdmaOpCode(bth.opcode);
        let isSupportedReqOpCode = isSupportedReqOpCodeRQ(qpc.qpType, bth.opcode); 
        let isRawPacket          = rdmaHeader.headerMetaData.isEmptyHeader;


        let reqStatus        = RDMA_REQ_ST_NORMAL;
        
        
        
        let isAccCheckPass = False;
        
        // for ACK/NACK, no need to check
        if (rdmaOpCodeNeedQueryMrTable) begin
            case ({ pack(isSendReq || isWriteReq), pack(isReadReq), pack(isAtomicReq), pack(isReadResp) })
                4'b1000: begin
                    isAccCheckPass = containAccessTypeFlag(qpc.rqAccessFlags, IBV_ACCESS_REMOTE_WRITE);
                end
                4'b0100: begin
                    isAccCheckPass = containAccessTypeFlag(qpc.rqAccessFlags, IBV_ACCESS_REMOTE_READ);
                end
                4'b0010: begin
                    isAccCheckPass = containAccessTypeFlag(qpc.rqAccessFlags, IBV_ACCESS_REMOTE_ATOMIC);
                end
                4'b0001: begin
                    isAccCheckPass = containAccessTypeFlag(qpc.rqAccessFlags, IBV_ACCESS_LOCAL_WRITE);
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isSendReq=", fshow(isSendReq),
                            ", isWriteReq=", fshow(isWriteReq),
                            ", isReadReq=", fshow(isReadReq),
                            ", isAtomicReq=", fshow(isAtomicReq),
                            ", bth=", fshow(bth)
                        )
                    );
                end
            endcase
        
        end
        else begin
            isAccCheckPass = True;
        end

        let reqAccFlags = genAccessFlagFromReqType(isSendReq, isReadReq, isWriteReq, isAtomicReq);

        if (!isRawPacket) begin
            if (!isAccCheckPass) begin
                reqStatus = RDMA_REQ_ST_INV_ACC_FLAG;
            end
            else if (!isSupportedReqOpCode) begin
                reqStatus = RDMA_REQ_ST_INV_OPCODE;
            end
        end

        reqStatusCheckStep2PipeQ.enq(tuple5(pktMetaDataAndQpc, reqStatus, rdmaOpCodeNeedQueryMrTable, reqAccFlags, reth));
        $display("time=%0t: ", $time, "reqStatusCheckStep1 pktMetaDataAndQpc=",  fshow(pktMetaDataAndQpc));
    endrule


    rule getMRQueryRespAndReqStatusCheckStep2;

        let {pktMetaDataAndQpc, reqStatus, rdmaOpCodeNeedQueryMrTable, reqAccFlags, reth} = reqStatusCheckStep2PipeQ.first;
        reqStatusCheckStep2PipeQ.deq;

        let pktMetaData = pktMetaDataAndQpc.metadata;


        let needWaitForPGTResponse  = False;
        let isMrValid               = False;
        let lowerAddrBoundOk        = False;
        let mrUpperAddrBound        = ?;
        let reqUpperAddrBound       = ?;
        let isMrKeyMatch            = False;
        let isAccTypeMatch          = False;

        if (rdmaOpCodeNeedQueryMrTable) begin
        

            
        
            let mrMaybe <- mrTableQueryCltInst.getResp;
            $display("mrMaybe=", fshow(mrMaybe));

            isMrValid = isValid(mrMaybe);

            if (mrMaybe matches tagged Valid .mr) begin
                isMrKeyMatch    = (truncate(reth.rkey) == mr.keyPart);
                
                isAccTypeMatch  = compareAccessTypeFlags(mr.accFlags, reqAccFlags);

                
                lowerAddrBoundOk = reth.va >= mr.baseVA;

                mrUpperAddrBound = mr.baseVA + zeroExtend(mr.len);
                reqUpperAddrBound = reth.va + zeroExtend(pktMetaData.pktPayloadLen);

                $display(
                    "reth.va=", fshow(reth.va), 
                    "pktMetaData.pktPayloadLen=", fshow(pktMetaData.pktPayloadLen),
                    "mr.baseVA=", mr.baseVA,
                    "mr.len=", mr.len);
                
                pgtQueryCltInst.putReq(PgtAddrTranslateReq{
                    mrEntry: mr,
                    addrToTrans: reth.va
                });
                needWaitForPGTResponse = True;
            end
        end

        

        let reqStatusCheckStep3PipeInfo = ReqStatusCheckStep3PipeInfo {
            pktMetaDataAndQpc           :   pktMetaDataAndQpc,
            reqStatus                   :   reqStatus,
            rdmaOpCodeNeedQueryMrTable  :   rdmaOpCodeNeedQueryMrTable,
            lowerAddrBoundOk            :   lowerAddrBoundOk,
            mrUpperAddrBound            :   mrUpperAddrBound,
            reqUpperAddrBound           :   reqUpperAddrBound,
            isMrValid                   :   isMrValid,
            needWaitForPGTResponse      :   needWaitForPGTResponse,
            isMrKeyMatch                :   isMrKeyMatch,
            isAccTypeMatch              :   isAccTypeMatch
        };

        reqStatusCheckStep3PipeQ.enq(reqStatusCheckStep3PipeInfo);

    endrule


    rule getMRQueryRespAndReqStatusCheckStep3;
        let reqStatusCheckStep3PipeInfo = reqStatusCheckStep3PipeQ.first;
        reqStatusCheckStep3PipeQ.deq;

        let pktMetaDataAndQpc           = reqStatusCheckStep3PipeInfo.pktMetaDataAndQpc;
        let reqStatus                   = reqStatusCheckStep3PipeInfo.reqStatus;
        let rdmaOpCodeNeedQueryMrTable  = reqStatusCheckStep3PipeInfo.rdmaOpCodeNeedQueryMrTable;
        let lowerAddrBoundOk            = reqStatusCheckStep3PipeInfo.lowerAddrBoundOk;
        let mrUpperAddrBound            = reqStatusCheckStep3PipeInfo.mrUpperAddrBound;
        let reqUpperAddrBound           = reqStatusCheckStep3PipeInfo.reqUpperAddrBound;
        let isMrValid                   = reqStatusCheckStep3PipeInfo.isMrValid;
        let needWaitForPGTResponse      = reqStatusCheckStep3PipeInfo.needWaitForPGTResponse;
        let isMrKeyMatch                = reqStatusCheckStep3PipeInfo.isMrKeyMatch;
        let isAccTypeMatch              = reqStatusCheckStep3PipeInfo.isAccTypeMatch;

        let pktMetaData = pktMetaDataAndQpc.metadata;
        let pktValid =  pktMetaData.pktValid;
        let isAccessRangeCheckPass = False;

        if (rdmaOpCodeNeedQueryMrTable) begin

            if (isMrValid) begin
                isAccessRangeCheckPass = lowerAddrBoundOk && mrUpperAddrBound >= reqUpperAddrBound;
            end

            if (!pktValid) begin
                reqStatus = RDMA_REQ_ST_INV_HEADER;
            end
            else if (!isMrKeyMatch) begin
                reqStatus = RDMA_REQ_ST_INV_MR_KEY;
            end
            else if (!isAccTypeMatch) begin
                reqStatus = RDMA_REQ_ST_INV_ACC_FLAG;
            end
            else if (!isAccessRangeCheckPass) begin
                reqStatus = RDMA_REQ_ST_INV_MR_REGION;
            end
        end
        
        getPGTQueryRespPipeQ.enq(tuple4(pktMetaDataAndQpc, reqStatus, needWaitForPGTResponse, rdmaOpCodeNeedQueryMrTable));

        $display("time=%0t: ", $time, "getMRQueryRespAndReqStatusCheckStep2 pktMetaDataAndQpc=",  fshow(pktMetaDataAndQpc));

    endrule

    rule recvAddrTransRespAndIssueDMA;
        let { pktMetaDataAndQpc, reqStatus, needWaitForPGTResponse, rdmaOpCodeNeedQueryMrTable } = getPGTQueryRespPipeQ.first;
        getPGTQueryRespPipeQ.deq;

        let pktMetaData = pktMetaDataAndQpc.metadata;
        let isZeroPayloadLen =  pktMetaData.isZeroPayloadLen;

        let phyAddr = 0;
        if (needWaitForPGTResponse) begin
            phyAddr <- pgtQueryCltInst.getResp;
        end

        Bool needIssueDMARequest = (
            needWaitForPGTResponse          && 
            reqStatus == RDMA_REQ_ST_NORMAL &&
            !isZeroPayloadLen
        );

        if (needIssueDMARequest) begin
            payloadConsumerControlClt.putReq(PayloadConReq{
                fragNum: pktMetaData.pktFragNum,
                consumeInfo: tagged WriteReqInfo DmaWriteMetaData {
                    startAddr: phyAddr,
                    len      : pktMetaData.pktPayloadLen
                }
            });
        end 
        else begin
            // the reason for discard packet should be that we have payload data, need to do dma, but some check failed, so
            // we need to discard data. But for packet like ACK/NACK, we don't want an DMA not because we encounter an error,
            // but because it really doesn't need DAM.
            let rdmaOpCodeNeedDMA = rdmaOpCodeNeedQueryMrTable;
            if (rdmaOpCodeNeedDMA && !isZeroPayloadLen) begin
                let req <- genDiscardPayloadReq(pktMetaData.pktFragNum, pktMetaData.pktPayloadLen);
                payloadConsumerControlClt.putReq(req);
            end
        end

        psnContextQueryReqPipeQ.enq(tuple3(pktMetaDataAndQpc, reqStatus, needIssueDMARequest));

        $display("time=%0t: ", $time, "recvAddrTransRespAndIssueDMA",
                 ", needWaitForPGTResponse=",  fshow(needWaitForPGTResponse),
                 ", needIssueDMARequest=",  fshow(needIssueDMARequest),
                 ", isZeroPayloadLen=", fshow(isZeroPayloadLen),
                 ", pktMetaDataAndQpc=",  fshow(pktMetaDataAndQpc)
        );
    endrule

    rule sendPsnContinousCheckRequest;
        let {pktMetaDataAndQpc, reqStatus, needIssueDMARequest} = psnContextQueryReqPipeQ.first;
        psnContextQueryReqPipeQ.deq;

        let pktMetaData     = pktMetaDataAndQpc.metadata;
        let rdmaHeader      = pktMetaData.pktHeader;
        let bth             = extractBTH(rdmaHeader.headerData);

        let isAtomicReq     = isAtomicReqRdmaOpCode(bth.opcode);
        let isFirstPkt      = isFirstRdmaOpCode(bth.opcode);
        let isMiddlePkt     = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt       = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt       = isOnlyRdmaOpCode(bth.opcode);

        let qpIdxPart = getIndexQP(bth.dqpn);

        let isPacketAbnormal        = reqStatus != RDMA_REQ_ST_NORMAL;

        let checkReq = ExpectedPsnCheckReq {
            qpnIdx                  : qpIdxPart,
            newIncomingPSN          : bth.psn,
            isPacketStateAbnormal   : isPacketAbnormal
        };
        let needCheckExpectedPSN = !isPacketAbnormal && (isFirstPkt || isMiddlePkt || isLastPkt || isOnlyPkt);

        if (needCheckExpectedPSN) begin
            expectedPsnManager.psnContextQuerySrv.request.put(checkReq);
        end
        
        psnContinuityCheckPipeQ.enq(tuple4(pktMetaDataAndQpc, reqStatus, needIssueDMARequest, needCheckExpectedPSN));

    endrule

    rule checkPsnContinuityAndDecideIfNeedReportPacketMeta;
        let {pktMetaDataAndQpc, reqStatus, needIssueDMARequest, needCheckExpectedPSN} = psnContinuityCheckPipeQ.first;
        psnContinuityCheckPipeQ.deq;

        let pktMetaData = pktMetaDataAndQpc.metadata;
        let rdmaHeader  = pktMetaData.pktHeader;
        
        let bth             = extractBTH(rdmaHeader.headerData);
        let isMiddlePkt     = isMiddleRdmaOpCode(bth.opcode);

        let needReportPacketMeta = True;

        let expectedPsn = 0;

        let canAutoAck = False;
        
        $display("time=%0t:", $time, " needCheckExpectedPSN=", fshow(needCheckExpectedPSN));

        if (needCheckExpectedPSN) begin
            let psnContinousCheckResp <- expectedPsnManager.psnContextQuerySrv.response.get;
            let needGenerateAck = psnContinousCheckResp.isQpPsnContinous && bth.ackReq;
            expectedPsn = psnContinousCheckResp.expectedPSN;
            canAutoAck = psnContinousCheckResp.isQpPsnContinous;
            $display("time=%0t:", $time, " psnContinousCheckResp=", fshow(psnContinousCheckResp), ", bth=", fshow(bth));

            if (needGenerateAck) begin
                let autoAckGenMeta = AutoAckGenMetaData {
                    srcMacIpIdx: rdmaHeader.headerMetaData.srcMacIpIdx,
                    pkey       : bth.pkey,
                    expectedPsn: expectedPsn,
                    qpn        : pktMetaDataAndQpc.qpc.peerQPN
                };

                autoAckGenMetaQ.enq(autoAckGenMeta);
                $display("time=%0t:", $time, " decide auto send ACK, autoAckGenMeta=", fshow(autoAckGenMeta));
            end

            if (psnContinousCheckResp.isAdjacentPsnContinous && isMiddlePkt) begin
                needReportPacketMeta = False;
            end
        end


        // For Debug Use
        // needReportPacketMeta = True;


        waitDMARespPipeQ.enq(tuple6(pktMetaDataAndQpc, reqStatus, expectedPsn, needIssueDMARequest, needReportPacketMeta, canAutoAck));
        
    endrule

    rule waitDMAFinishAndWriteMetaToHost;
        let { pktMetaDataAndQpc, reqStatus, expectedPsn, needIssueDMARequest, needReportPacketMeta, canAutoAck } = waitDMARespPipeQ.first;
        waitDMARespPipeQ.deq;

        let pktMetaData = pktMetaDataAndQpc.metadata;
        let rdmaHeader  = pktMetaData.pktHeader;
        

        let bth             = extractBTH(rdmaHeader.headerData);
        let reth            = extractPriRETH(rdmaHeader.headerData, bth.trans);
        let rethSecondary   = extractSecRETH(rdmaHeader.headerData, bth.trans, bth.opcode);
        let aeth            = extractAETH(rdmaHeader.headerData);
        let nreth           = extractNRETH(rdmaHeader.headerData);
        let immDT           = extractImmDt(rdmaHeader.headerData, bth.opcode, bth.trans);
        $display("nreth=", fshow(nreth));
        let isAckPkt        = isAckRdmaOpCode(bth.opcode);
        let isRawPacket     = rdmaHeader.headerMetaData.isEmptyHeader;


        if (needIssueDMARequest) begin
            let _ <- payloadConsumerControlClt.getResp;
        end

        C2hReportEntry rptEntry = ?;

        rptEntry.reqStatus      = reqStatus;

        rptEntry.trans          = bth.trans;
        rptEntry.opcode         = bth.opcode;
        rptEntry.solicited      = bth.solicited;
        rptEntry.dqpn           = bth.dqpn;
        rptEntry.psn            = bth.psn;
        rptEntry.padCnt         = bth.padCnt;

        rptEntry.va             = reth.va;
        rptEntry.rkey           = reth.rkey;
        rptEntry.dlen           = isRawPacket ? zeroExtend(pktMetaData.pktPayloadLen) : reth.dlen;

        rptEntry.secondaryVa    = rethSecondary.va;
        rptEntry.secondaryRkey  = rethSecondary.rkey;

        rptEntry.code           = aeth.code;
        rptEntry.value          = aeth.value;
        rptEntry.msn            = isAckPkt ? aeth.msn : zeroExtend(bth.pkey);
        rptEntry.lastRetryPSN   = nreth.lastRetryPSN;
        rptEntry.expectedPsn    = expectedPsn;
        rptEntry.immDt          = immDT.data;
        rptEntry.canAutoAck     = canAutoAck;

        if (needReportPacketMeta) begin
            pktReportEntryQ.enq(rptEntry);
        end
        $display("time=%0t: ", $time, "waitDMAFinishAndWriteMetaToHost pktMetaDataAndQpc=",  fshow(pktMetaDataAndQpc));
    endrule

    rule handleResetExpectedPsnReq;
        let {qpnIdx, newExpectedPSN, psnUpadteAction} = setRqExpectedPsnReqQ.first;
        setRqExpectedPsnReqQ.deq;
        case (psnUpadteAction)
            RqPsnManagerPsnUpadteActionReset: begin
                expectedPsnManager.resetPSN(qpnIdx);
            end
            RqPsnManagerPsnUpadteActionUpdateErrorRecoveryPoint: begin
                expectedPsnManager.submitQpReturnToNormalStateRequest(qpnIdx, newExpectedPSN);
            end
        endcase
    endrule

    interface setRqExpectedPsnReqIn         = toPut(setRqExpectedPsnReqQ);
    
    interface pktMetaDataPipeIn             = toPut(rdmaPktMetaDataInQ);
    interface mrTableQueryClt               = mrTableQueryCltInst.clt;
    interface pgtQueryClt                   = pgtQueryCltInst.clt;
    interface payloadConsumerControlPortClt = payloadConsumerControlClt.clt;
    interface pktReportEntryPipeOut         = toPipeOut(pktReportEntryQ);
    interface autoAckMetaPipeOut         = toPipeOut(autoAckGenMetaQ);
endmodule


interface RQReportEntryToRingbufDesc;
    interface Put#(C2hReportEntry) pktReportEntryPipeIn;
    interface PipeOut#(RingbufRawDescriptor) ringbufDescPipeOut;
endinterface

typedef enum {
    RQReportEntryToRingbufDescStatusOutputBasicInfo,
    RQReportEntryToRingbufDescStatusOutputExtraInfo
} RQReportEntryToRingbufDescStatus deriving(Bits, Eq);

module mkRQReportEntryToRingbufDesc(RQReportEntryToRingbufDesc);
    FIFOF#(C2hReportEntry) pktReportEntryPipeInQ <- mkFIFOF;
    FIFOF#(RingbufRawDescriptor) ringbufDescPipeOutQ <- mkFIFOF;

    Reg#(RQReportEntryToRingbufDescStatus) state <- mkReg(RQReportEntryToRingbufDescStatusOutputBasicInfo);

    // rule debug;
    //     if (!pktReportEntryPipeInQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: pktReportEntryPipeInQ");
    //     end
    //     if (!pktReportEntryPipeInQ.notEmpty) begin
    //         $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: pktReportEntryPipeInQ");
    //     end
    //     if (!ringbufDescPipeOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: ringbufDescPipeOutQ");
    //     end                      
    // endrule

    rule outputDesc ;
        let reportEntry = pktReportEntryPipeInQ.first;

        let bth = MeatReportQueueDescFragBTH {
            trans:      reportEntry.trans,
            opcode:     reportEntry.opcode,
            dqpn:       reportEntry.dqpn,
            psn:        reportEntry.psn,
            solicited:  reportEntry.solicited,
            ackReq:     reportEntry.ackReq,
            padCnt:     reportEntry.padCnt,
            reserved1:  unpack(0)
        };

        let reth = MeatReportQueueDescFragRETH {
            va: reportEntry.va,
            rkey: reportEntry.rkey,
            dlen: reportEntry.dlen
        };

        let secReth = MeatReportQueueDescFragSecondaryRETH {
            secondaryRkey: reportEntry.secondaryRkey,
            secondaryVa  : reportEntry.secondaryVa
        };

        let aeth = MeatReportQueueDescFragAETH {
            code:           reportEntry.code,
            value:          reportEntry.value,
            msn:            reportEntry.msn,
            lastRetryPSN:   reportEntry.lastRetryPSN,
            reserved1:      unpack(0)
        };

        let immDt = MeatReportQueueDescFragImmDT {
            data:           reportEntry.immDt
        };


        let isHasImmData = rdmaReqHasImmDt(reportEntry.opcode);

        let opcode = {pack(reportEntry.trans), pack(reportEntry.opcode)};
        if (state == RQReportEntryToRingbufDescStatusOutputBasicInfo) begin
            case (opcode)
                fromInteger(valueOf(RC_SEND_FIRST)),
                fromInteger(valueOf(RC_SEND_MIDDLE)),
                fromInteger(valueOf(RC_SEND_LAST)),
                fromInteger(valueOf(RC_SEND_ONLY)):
                begin
                    let ent = MeatReportQueueDescBth{
                        canAutoAck  :   reportEntry.canAutoAck,
                        reqStatus   :   reportEntry.reqStatus,
                        bth         :   bth,
                        expectedPSN :   reportEntry.expectedPsn,
                        msn         :   reportEntry.msn,
                        reserved1   :   unpack(0)
                    };
                    ringbufDescPipeOutQ.enq(pack(ent));
                    pktReportEntryPipeInQ.deq;
                    $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "RQ send recv packet meta to host: ", fshow(ent));
                end
                fromInteger(valueOf(RC_RDMA_WRITE_FIRST)),
                fromInteger(valueOf(RC_RDMA_WRITE_MIDDLE)),
                fromInteger(valueOf(RC_RDMA_WRITE_LAST)),
                fromInteger(valueOf(RC_RDMA_WRITE_LAST_WITH_IMMEDIATE)),
                fromInteger(valueOf(RC_RDMA_WRITE_ONLY)),
                fromInteger(valueOf(RC_RDMA_WRITE_ONLY_WITH_IMMEDIATE)),
                fromInteger(valueOf(RC_RDMA_READ_REQUEST)),
                fromInteger(valueOf(RC_RDMA_READ_RESPONSE_FIRST)),
                fromInteger(valueOf(RC_RDMA_READ_RESPONSE_MIDDLE)),
                fromInteger(valueOf(RC_RDMA_READ_RESPONSE_LAST)),
                fromInteger(valueOf(RC_RDMA_READ_RESPONSE_ONLY)),
                fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_FIRST)),
                fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_MIDDLE)),
                fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_LAST)),
                fromInteger(valueOf(XRC_RDMA_READ_RESPONSE_ONLY)),
                fromInteger(valueOf(DTLD_EXT_RAW_PACKET_WRITE_ONLY_WITH_IMMEDIATE)):
                begin
                    let ent = MeatReportQueueDescBthReth{
                        canAutoAck  :   reportEntry.canAutoAck,
                        reserved1   :   unpack(0),
                        msn         :   reportEntry.msn,
                        reqStatus   :   reportEntry.reqStatus,
                        bth         :   bth,
                        reth        :   reth,
                        expectedPSN :   reportEntry.expectedPsn
                    };
                    if (opcode == fromInteger(valueOf(RC_RDMA_READ_REQUEST)) || isHasImmData) begin
                        state <= RQReportEntryToRingbufDescStatusOutputExtraInfo;
                    end
                    else begin
                        pktReportEntryPipeInQ.deq;
                    end
                    ringbufDescPipeOutQ.enq(pack(ent));
                    $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "RQ send recv packet meta to host: ", fshow(ent));
                end
                fromInteger(valueOf(RC_ACKNOWLEDGE)),
                fromInteger(valueOf(RC_ATOMIC_ACKNOWLEDGE)),
                fromInteger(valueOf(XRC_ACKNOWLEDGE)),
                fromInteger(valueOf(XRC_ATOMIC_ACKNOWLEDGE)):
                begin
                    let ent = MeatReportQueueDescBthAeth{
                        reqStatus   :   reportEntry.reqStatus,
                        bth         :   bth,
                        aeth        :   aeth,
                        reserved1   :   unpack(0),
                        reserved2   :   unpack(0)
                    };
                    pktReportEntryPipeInQ.deq;
                    ringbufDescPipeOutQ.enq(pack(ent));
                    $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "RQ send recv packet meta to host: ", fshow(ent));
                end

                default: begin
                    pktReportEntryPipeInQ.deq;
                    $display("Warn: Received Not Supported Packet, Will not report to software.");
                end
            endcase
        end 
        else if (state == RQReportEntryToRingbufDescStatusOutputExtraInfo) begin
            case (reportEntry.opcode)
                RDMA_READ_REQUEST: begin
                    let ent = MeatReportQueueDescSecondaryReth{
                        secReth     :   secReth,
                        reserved1   :   unpack(0)
                    };
                    
                    state <= RQReportEntryToRingbufDescStatusOutputBasicInfo;
                    ringbufDescPipeOutQ.enq(pack(ent));
                    pktReportEntryPipeInQ.deq;
                    $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "RQ send recv packet meta to host: ", fshow(ent));
                end
                SEND_LAST_WITH_IMMEDIATE      ,
                SEND_ONLY_WITH_IMMEDIATE      ,
                RDMA_WRITE_LAST_WITH_IMMEDIATE,
                RDMA_WRITE_ONLY_WITH_IMMEDIATE: begin
                    let ent = MeatReportQueueDescImmDT{
                        immDt       :   immDt,
                        reserved1   :   unpack(0)
                    };
                    
                    state <= RQReportEntryToRingbufDescStatusOutputBasicInfo;
                    ringbufDescPipeOutQ.enq(pack(ent));
                    pktReportEntryPipeInQ.deq;
                    $display("time=%0t: ", $time, "SOFTWARE DEBUG POINT ", "RQ send recv packet meta to host: ", fshow(ent));
                end
                default: begin
                    $display("Warn: Received Not Supported Packet, Will not report to software.");
                end
            endcase
        end
    endrule






    interface pktReportEntryPipeIn  = toPut(pktReportEntryPipeInQ);
    interface ringbufDescPipeOut    = toPipeOut(ringbufDescPipeOutQ);

endmodule
