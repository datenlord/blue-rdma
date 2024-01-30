import BuildVector :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import ExtractAndPrependPipeOut :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadGen :: *;
import PrimUtils :: *;
import SendQ :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

module mkSimGenWorkQueueElemByOpCode#(
    PipeOut#(WorkReqOpCode) workReqOpCodePipeIn,
    // PipeOut#(PSN) psnPipeIn,
    Length minLength,
    Length maxLength,
    TypeQP qpType,
    WorkReqSendFlag flags
)(Vector#(vSz, PipeOut#(WorkQueueElem)));
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Vector#(1, PipeOut#(NumSGE)) sgeNumPipeOutVec <-
        mkRandomValueInRangePipeOut(fromInteger(1), fromInteger(valueOf(MAX_SGE)));

    PipeOut#(WorkReqID) workReqIdPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(PSN) psnPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IP) ipAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(MAC) macAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) compPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(Long) swapPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(IMM) immDtPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(RKEY) rkey2InvPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR) remoteAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR)  localAddrPipeOut <- mkGenericRandomPipeOut;

    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);
    let payloadLenPipeOut <- mkRandomLenPipeOut(minLength, maxLength);

    FIFOF#(WorkQueueElem) wqeOutQ <- mkFIFOF;
    Vector#(vSz, PipeOut#(WorkQueueElem)) resultPipeOutVec <-
        mkForkVector(toPipeOut(wqeOutQ));

    Reg#(IdxSGL) sglIdxReg <- mkReg(0);
    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);
    Reg#(Bool) busyReg <- mkReg(True);

    rule genSGE if (busyReg);
        let sgeNum = sgeNumPipeOutVec[0].first;

        let localAddr = localAddrPipeOut.first;
        localAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isFirst = isZero(sglIdxReg);
        let isLast  = isAllOnesR(sglIdxReg); // || (sgeNum - 1 == zeroExtend(sglIdxReg));
        let sge = ScatterGatherElem {
            laddr  : localAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirst,
            isLast : isLast
        };
        sglRegVec[sglIdxReg] <= sge;

        if (isLast) begin
            sgeNumPipeOutVec[0].deq;
            sglIdxReg <= 0;
            busyReg <= False;
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end

        // $display(
        //     "time=%0t: genSGE", $time,
        //     ", sgeNum=%0d", sgeNum,
        //     ", sglIdxReg=%0d", sglIdxReg,
        //     ", localAddr=%h", localAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", isFirst=", fshow(isFirst),
        //     ", isLast=", fshow(isLast)
        // );
    endrule

    rule genWQE if (!busyReg);
        let wrID = workReqIdPipeOut.first;
        workReqIdPipeOut.deq;

        let wrOpCode = workReqOpCodePipeIn.first;
        workReqOpCodePipeIn.deq;

        let psn = psnPipeOut.first;
        psnPipeOut.deq;

        let ipAddr = ipAddrPipeOut.first;
        ipAddrPipeOut.deq;
        let macAddr = macAddrPipeOut.first;
        macAddrPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let remoteAddr = remoteAddrPipeOut.first;
        remoteAddrPipeOut.deq;

        let comp = compPipeOut.first;
        compPipeOut.deq;

        let swap = swapPipeOut.first;
        swapPipeOut.deq;

        let immDt = immDtPipeOut.first;
        immDtPipeOut.deq;

        let rkey2Inv = rkey2InvPipeOut.first;
        rkey2InvPipeOut.deq;

        let isReadWR   = isReadWorkReq(wrOpCode);
        let isAtomicWR = isAtomicWorkReq(wrOpCode);
        let hasImmDt   = workReqHasImmDt(wrOpCode);
        let hasInv     = workReqHasInv(wrOpCode);
        let hasComp    = workReqHasComp(wrOpCode);
        let hasSwap    = workReqHasSwap(wrOpCode);

        QPN sqpn = getDefaultQPN;
        QPN srqn = sqpn; // For XRC
        QPN dqpn = getDefaultQPN;
        QKEY qkey = dontCareValue;

        let sglZeroIdx = 0;
        let sgl = readVReg(sglRegVec);
        if (isAtomicWR) begin
            sgl[sglZeroIdx].isLast = True;
            sgl[sglZeroIdx].len = fromInteger(valueOf(ATOMIC_WORK_REQ_LEN));
        end
        if (isReadWR) begin
            sgl[sglZeroIdx].isLast = True;
        end

        let wqe = WorkQueueElem {
            id     : wrID,
            opcode : wrOpCode,
            flags  : enum2Flag(flags),
            qpType : qpType,
            psn    : psn,
            pmtu   : pmtu,
            dqpIP  : ipAddr,
            macAddr: macAddr,
            sgl    : sgl,
            raddr  : remoteAddr,
            rkey   : dontCareValue,
            // pkey   : dontCareValue,
            sqpn   : sqpn,
            dqpn   : dqpn,
            comp   : hasComp ? (tagged Valid comp) : (tagged Invalid),
            swap   : hasSwap ? (tagged Valid swap) : (tagged Invalid),
            immDtOrInvRKey: hasImmDt ? tagged Valid tagged Imm immDt : (hasInv ? tagged Valid tagged RKey rkey2Inv : tagged Invalid),
            srqn   : tagged Valid srqn, // for XRC
            qkey   : tagged Valid qkey, // for UD
            isFirst: True,
            isLast : True
        };
        wqeOutQ.enq(wqe);
        busyReg <= True;
        // $display("time=%0t: generate random WQE=", $time, fshow(wqe));
    endrule

    return resultPipeOutVec;
endmodule

module mkRandomWorkQueueElemWithOutPayload#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkQueueElem)));
    Vector#(3, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_RDMA_READ,
        IBV_WR_ATOMIC_CMP_AND_SWP,
        IBV_WR_ATOMIC_FETCH_AND_ADD
    );
    let qpType = IBV_QPT_XRC_SEND;
    let wrFlags = IBV_SEND_SIGNALED;
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    let resultPipeOutVec <- mkSimGenWorkQueueElemByOpCode(
        workReqOpCodePipeOut, minLength, maxLength, qpType, wrFlags
    );
    return resultPipeOutVec;
endmodule

module mkRandomWorkQueueElemWithPayload#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkQueueElem)));
    Vector#(6, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV,
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_RDMA_READ_RESP
    );
    let qpType = IBV_QPT_XRC_SEND;
    let wrFlags = IBV_SEND_SIGNALED;
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    let resultPipeOutVec <- mkSimGenWorkQueueElemByOpCode(
        workReqOpCodePipeOut, minLength, maxLength, qpType, wrFlags
    );
    return resultPipeOutVec;
endmodule
/*
module mkRandomWorkQueueElemRawPkt#(
    Length minLength, Length maxLength
)(Vector#(vSz, PipeOut#(WorkQueueElem)));
    Vector#(6, WorkReqOpCode) workReqOpCodeVec = vec(
        IBV_WR_SEND,
        IBV_WR_SEND_WITH_IMM,
        IBV_WR_SEND_WITH_INV,
        IBV_WR_RDMA_WRITE,
        IBV_WR_RDMA_WRITE_WITH_IMM,
        IBV_WR_RDMA_READ_RESP
    );
    let qpType = IBV_QPT_RAW_PACKET;
    let wrFlags = IBV_SEND_SIGNALED;
    let workReqOpCodePipeOut <- mkRandomItemFromVec(workReqOpCodeVec);
    let resultPipeOutVec <- mkSimGenWorkQueueElemByOpCode(
        workReqOpCodeVec, minLength, maxLength, qpType, wrFlags
    );
    return resultPipeOutVec;
endmodule
*/
(* doc = "testcase" *)
module mkTestSendQueueNormalCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 10241;
    let genPayload = True;
    let result <- mkTestSendQueueNormalAndZeroLenCase(
        genPayload, minDmaLength, maxDmaLength
    );
endmodule

(* doc = "testcase" *)
module mkTestSendQueueNoPayloadCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 10241;
    let genPayload = False;
    let result <- mkTestSendQueueNormalAndZeroLenCase(
        genPayload, minDmaLength, maxDmaLength
    );
endmodule

module mkTestSendQueueNormalAndZeroLenCase#(
    Bool genPayload, Length minDmaLength, Length maxDmaLength
)(Empty);
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);

    // WQE generation
    Vector#(2, PipeOut#(WorkQueueElem)) wqePipeOutVec <- genPayload ?
        mkRandomWorkQueueElemWithPayload(minDmaLength, maxDmaLength) :
        mkRandomWorkQueueElemWithOutPayload(minDmaLength, maxDmaLength);

    // Request payload DataStream generation
    // let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // let dataStreamWithPaddingPipeOut <- mkDataStreamAddPadding(
    //     simDmaReadSrv.dataStream
    // );
    // let dataStreamWithPaddingPipeOut4Ref <- mkBufferN(getMaxFragBufSize, dataStreamWithPaddingPipeOut);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);
    let shouldAddPadding = True;
    let payloadGenerator <- mkPayloadGenerator(clearReg, shouldAddPadding, dmaReadCntrl);

    let dut <- mkSendQ(clearReg, payloadGenerator);
    mkConnection(dut.wqeInPut, toGet(wqePipeOutVec[0]));
    let wqePipeOut4Ref <- mkBufferN(getMaxFragBufSize, wqePipeOutVec[1]);

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        dut.rdmaDataStreamPipeOut
    );
    // Convert header DataStream to RdmaHeader
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );
    // // Remove empty payload DataStream
    // let filteredPayloadDataStreamPipeOut <- mkPipeFilter(
    //     filterEmptyDataStream,
    //     headerAndMetaDataAndPayloadPipeOut.payload
    // );
    let udpInfoPipeOut4Ref <- mkBufferN(getMaxFragBufSize, dut.udpInfoPipeOut);
    FIFOF#(Tuple2#(HeaderByteNum, MAC)) headerLenAndMacAddrQ <- mkFIFOF;

    Reg#(PktLen) payloadLenReg <- mkRegU;
    Reg#(PSN)    curPsnReg <- mkRegU;
    Reg#(Bool) psnIsValidReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(wqePipeOut4Ref);
    // mkSink(dut.udpInfoPipeOut);
    // mkSink(dut.rdmaDataStreamPipeOut);
    // mkSink(filteredPayloadDataStreamPipeOut);

    rule clearAll if (clearReg);
        clearReg <= False;
        psnIsValidReg <= False;
        $display("time=%0t: clearAll", $time);
    endrule
/*
    rule compareWorkReq;
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        immAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestSendQueueNormalAndZeroLenCase",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );
        // $display("time=%0t: WR=", $time, fshow(pendingWR.wr));
    endrule
*/
    rule compareRdmaReqHeader if (!clearReg);
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        $display("time=%0t: BTH=", $time, fshow(bth));

        if (psnIsValidReg) begin
            curPsnReg <= curPsnReg + 1;

            immAssert(
                bth.psn == curPsnReg,
                "bth.psn correctness assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format("bth.psn=%h shoud == curPsnReg=%h", bth.psn, curPsnReg)
            );
        end
        else begin
            curPsnReg <= bth.psn + 1;
        end

        let refWQE = wqePipeOut4Ref.first;
        let wrStartPSN = refWQE.psn;
        headerLenAndMacAddrQ.enq(tuple2(
            rdmaHeader.headerMetaData.headerLen, refWQE.macAddr
        ));

        if (isOnlyRdmaOpCode(rdmaOpCode)) begin
            wqePipeOut4Ref.deq;
            // dut.udpInfoPipeOut.deq;
            psnIsValidReg <= False;

            // let isReadWR = isReadWorkReq(refWQE.opcode);
            // if (isReadWR) begin
            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn read request packet assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format(
                    "bth.psn=%h should == wrStartPSN=%h when refWQE.opcode=",
                    bth.psn, wrStartPSN, fshow(refWQE.opcode)
                )
            );
            // end
            // else begin
            //     immAssert(
            //         bth.psn == wrStartPSN && bth.psn == wrEndPSN,
            //         "bth.psn only request packet assertion @ mkTestSendQueueNormalAndZeroLenCase",
            //         $format(
            //             "bth.psn=%h should == wrStartPSN=%h and bth.psn=%h should == wrEndPSN=%h",
            //             bth.psn, wrStartPSN, bth.psn, wrEndPSN,
            //             ", when refWQE.opcode=",
            //             fshow(refWQE.opcode)
            //         )
            //     );
            // end
        end
        else if (isLastRdmaOpCode(rdmaOpCode)) begin
            wqePipeOut4Ref.deq;
            psnIsValidReg <= False;

            // immAssert(
            //     bth.psn == wrEndPSN,
            //     "bth.psn last request packet assertion @ mkTestSendQueueNormalAndZeroLenCase",
            //     $format("bth.psn=%h shoud == wrEndPSN=%h", bth.psn, wrEndPSN)
            // );
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            // dut.udpInfoPipeOut.deq;
            psnIsValidReg <= True;

            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn first request packet assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            immAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle request packet assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA request opcode"
                )
            );
            // immAssert(
            //     psnInRangeExclusive(bth.psn, wrStartPSN, wrEndPSN),
            //     "bth.psn between wrStartPSN and wrEndPSN assertion @ mkTestSendQueueNormalAndZeroLenCase",
            //     $format(
            //         "bth.psn=%h should > wrStartPSN=%h and bth.psn=%h should < wrEndPSN=%h",
            //         bth.psn, wrStartPSN, bth.psn, wrEndPSN,
            //         ", when refWQE.opcode=", fshow(refWQE.opcode),
            //         " and rdmaOpCode=", fshow(rdmaOpCode)
            //     )
            // );
        end

        let isRespPkt = True;
        immAssert(
            transTypeMatchQpType(transType, refWQE.qpType, isRespPkt),
            "transTypeMatchQpType assertion @ mkTestSendQueueNormalAndZeroLenCase",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(refWQE.qpType),
                " and isRespPkt=", fshow(isRespPkt)
            )
        );
        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, refWQE.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestSendQueueNormalAndZeroLenCase",
            $format(
                "RDMA request opcode=", fshow(rdmaOpCode),
                " should match workReqOpCode=", fshow(refWQE.opcode)
            )
        );

        // It must compare header not payload,
        // since WR might have zero length
        countDown.decr;
    endrule

    rule checkPktLen if (!clearReg);
        let pktFrag = headerAndMetaDataAndPayloadPipeOut.payload.first;
        headerAndMetaDataAndPayloadPipeOut.payload.deq;

        let maybePktFragLen = calcFragByteNumFromByteEn(pktFrag.byteEn);
        immAssert(
            isValid(maybePktFragLen),
            "maybePktFragLen assertion @ mkTestSendQueueNormalAndZeroLenCase",
            $format(
                "isValid(maybePktFragLen)=", fshow(isValid(maybePktFragLen)),
                " should be valid"
            )
        );

        let pktFragLen = unwrapMaybe(maybePktFragLen);
        let totalPayloadLen = payloadLenReg;
        if (pktFrag.isFirst) begin
            totalPayloadLen = zeroExtend(pktFragLen);
        end
        else begin
            totalPayloadLen = payloadLenReg + zeroExtend(pktFragLen);
        end
        payloadLenReg <= totalPayloadLen;

        if (pktFrag.isLast) begin
            let udpPktInfo = udpInfoPipeOut4Ref.first;
            udpInfoPipeOut4Ref.deq;

            let { headerLen, expectedMacAddr } = headerLenAndMacAddrQ.first;
            headerLenAndMacAddrQ.deq;

            immAssert(
                udpPktInfo.macAddr == expectedMacAddr,
                "macAddr assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format(
                    "udpPktInfo.macAddr=%h shoud == expectedMacAddr=%h",
                    udpPktInfo.macAddr, expectedMacAddr
                )
            );

            immAssert(
                udpPktInfo.pktLen == totalPayloadLen + zeroExtend(headerLen),
                "udpPktInfo.pktLen assertion @ mkTestSendQueueNormalAndZeroLenCase",
                $format(
                    "udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
                    " should == totalPayloadLen=%0d", totalPayloadLen,
                    " + headerLen=%0d", headerLen
                )
            );
            $display(
                "time=%0t: checkPktLen", $time,
                ", udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
                ", totalPayloadLen=%0d", totalPayloadLen,
                ", headerLen=%0d", headerLen,
                ", udpPktInfo.macAddr=%h", udpPktInfo.macAddr,
                ", udpPktInfo.ipAddr=", fshow(udpPktInfo.ipAddr)
            );
        end
    endrule
/*
    rule compareRdmaReqPayload;
        let payloadDataStream = filteredPayloadDataStreamPipeOut.first;
        filteredPayloadDataStreamPipeOut.deq;

        let refDataStream = dataStreamWithPaddingPipeOut4Ref.first;
        dataStreamWithPaddingPipeOut4Ref.deq;

        immAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestSendQueueNormalAndZeroLenCase",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
*/
endmodule
