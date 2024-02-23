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

    let sgeMinNum = 1;
    Vector#(1, PipeOut#(NumSGE)) sgeNumPipeOutVec <-
        mkRandomValueInRangePipeOut(fromInteger(sgeMinNum), fromInteger(valueOf(MAX_SGE)));
    let sgeNumPipeOut = sgeNumPipeOutVec[0];

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

    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);
    Reg#(IdxSGL) sglIdxReg <- mkReg(0);
    Reg#(Length) totalLenReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(True);

    rule genSGE if (busyReg);
        let sgeNum = sgeNumPipeOutVec[0].first;

        let localAddr = localAddrPipeOut.first;
        localAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isZeroPayloadLen = isZero(payloadLen);
        let isFirstSGE = isZeroPayloadLen || isZero(sglIdxReg);
        let isLastSGE  = isZeroPayloadLen || isAllOnesR(sglIdxReg) ||
            (sgeNum - 1 == zeroExtend(sglIdxReg));
        let sge = ScatterGatherElem {
            laddr  : localAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirstSGE,
            isLast : isLastSGE
        };
        sglRegVec[sglIdxReg] <= sge;

        if (isFirstSGE) begin
            totalLenReg <= payloadLen;
        end
        else begin
            totalLenReg <= totalLenReg + payloadLen;
        end

        if (isLastSGE) begin
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
        //     ", isFirstSGE=", fshow(isFirstSGE),
        //     ", isLastSGE=", fshow(isLastSGE)
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
            id            : wrID,
            opcode        : wrOpCode,
            flags         : enum2Flag(flags),
            qpType        : qpType,
            psn           : psn,
            pmtu          : pmtu,
            dqpIP         : ipAddr,
            macAddr       : macAddr,
            sgl           : sgl,
            totalLen      : totalLenReg,
            raddr         : remoteAddr,
            rkey          : dontCareValue,
            sqpn          : sqpn,
            dqpn          : dqpn,
            comp          : hasComp ? (tagged Valid comp) : (tagged Invalid),
            swap          : hasSwap ? (tagged Valid swap) : (tagged Invalid),
            immDtOrInvRKey: hasImmDt ? tagged Valid tagged Imm immDt : (hasInv ? tagged Valid tagged RKey rkey2Inv : tagged Invalid),
            srqn          : tagged Valid srqn, // for XRC
            qkey          : tagged Valid qkey, // for UD
            isFirst       : True,
            isLast        : True
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

(* doc = "testcase" *)
module mkTestSendQueueRawPktCase(Empty);
    let pmtu = IBV_MTU_256;
    let pmtuLen = calcPmtuLen(pmtu);
    let fixedLength = calcPmtuLen(pmtu);

    Reg#(Bool) clearReg <- mkReg(True);

    // WQE generation
    PipeOut#(IP)   ipAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(MAC) macAddrPipeOut <- mkGenericRandomPipeOut;
    FIFOF#(WorkQueueElem) wqeQ <- mkFIFOF;
    FIFOF#(WorkQueueElem) wqeRefQ <- mkSizedFIFOF(getMaxFragBufSize);
    let wqePipeOut4Ref = toPipeOut(wqeRefQ);

    // Request payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // let dataStreamWithPaddingPipeOut <- mkDataStreamAddPadding(
    //     simDmaReadSrv.dataStream
    // );
    let dataStreamPipeOut4Ref <- mkBufferN(getMaxFragBufSize, simDmaReadSrv.dataStream);

    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv.dmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(clearReg, dmaReadCntrl);

    let dut <- mkSendQ(clearReg, payloadGenerator);
    mkConnection(dut.srvPort.request, toGet(wqeQ));

    Reg#(PktLen) payloadLenReg <- mkRegU;
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(dut.rdmaDataStreamPipeOut);
    // mkSink(dataStreamPipeOut4Ref);
    // mkSink(dut.udpInfoPipeOut);
    // mkSink(wqePipeOut4Ref);

    rule clearAll if (clearReg);
        clearReg <= False;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule genWQE if (!clearReg);
        let ipAddr = ipAddrPipeOut.first;
        ipAddrPipeOut.deq;
        let macAddr = macAddrPipeOut.first;
        macAddrPipeOut.deq;

        let sge = ScatterGatherElem {
            laddr  : 0,
            len    : zeroExtend(fixedLength),
            lkey   : dontCareValue,
            isFirst: True,
            isLast : True
        };
        let dummySGE = sge;
        let sgl = vec(sge, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE);

        let wqe = WorkQueueElem {
            id            : dontCareValue,
            opcode        : IBV_WR_RDMA_READ, // dontCareValue
            flags         : enum2Flag(IBV_SEND_NO_FLAGS),
            qpType        : IBV_QPT_RAW_PACKET,
            psn           : 0,
            pmtu          : pmtu,
            dqpIP         : ipAddr,
            macAddr       : macAddr,
            sgl           : sgl,
            totalLen      : zeroExtend(fixedLength),
            raddr         : dontCareValue,
            rkey          : dontCareValue,
            sqpn          : getDefaultQPN,
            dqpn          : getDefaultQPN,
            comp          : tagged Invalid,
            swap          : tagged Invalid,
            immDtOrInvRKey: tagged Invalid,
            srqn          : tagged Invalid,
            qkey          : tagged Invalid,
            isFirst       : True,
            isLast        : True
        };
        wqeQ.enq(wqe);
        wqeRefQ.enq(wqe);
    endrule

    rule discardSendResp if (!clearReg);
        let sendResp <- dut.srvPort.response.get;
        // countDown.decr;
    endrule

    rule checkAddr if (!clearReg);
        let udpPktInfo = dut.udpInfoPipeOut.first;
        dut.udpInfoPipeOut.deq;

        let wqe = wqePipeOut4Ref.first;
        wqePipeOut4Ref.deq;

        immAssert(
            udpPktInfo.macAddr == wqe.macAddr,
            "macAddr assertion @ mkTestSendQueueRawPktCase",
            $format(
                "udpPktInfo.macAddr=%h shoud == wqe.macAddr=%h",
                udpPktInfo.macAddr, wqe.macAddr
            )
        );
        immAssert(
            udpPktInfo.pktLen == pmtuLen,
            "udpPktInfo.pktLen assertion @ mkTestSendQueueRawPktCase",
            $format(
                "udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
                " should == pmtuLen=%0d", pmtuLen
            )
        );
    endrule

    rule checkPktFrag if (!clearReg);
        let pktFrag = dut.rdmaDataStreamPipeOut.first;
        dut.rdmaDataStreamPipeOut.deq;

        let expectedPktFrag = dataStreamPipeOut4Ref.first;
        dataStreamPipeOut4Ref.deq;

        immAssert(
            pktFrag.data == expectedPktFrag.data &&
            pktFrag.byteEn == expectedPktFrag.byteEn,
            "payload assertion @ mkTestSendQueueRawPktCase",
            $format(
                "pktFrag.data=%h", pktFrag.data,
                " should == expectedPktFrag.data=%h", expectedPktFrag.data,
                " and pktFrag.byteEn=%h", pktFrag.byteEn,
                " should == expectedPktFrag.byteEn=%h", expectedPktFrag.byteEn
            )
        );

        let maybePktFragLen = calcFragByteNumFromByteEn(pktFrag.byteEn);
        immAssert(
            isValid(maybePktFragLen),
            "maybePktFragLen assertion @ mkTestSendQueueRawPktCase",
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
            immAssert(
                totalPayloadLen == fixedLength,
                "totalPayloadLen assertion @ mkTestSendQueueRawPktCase",
                $format(
                    "totalPayloadLen=%0d", totalPayloadLen,
                    " should == fixedLength=%0d", fixedLength
                )
            );
            // $display(
            //     "time=%0t: checkOutput", $time,
            //     ", fixedLength=%0d", fixedLength,
            //     ", totalPayloadLen=%0d", totalPayloadLen,
            //     ", pktFrag.isFirst=", fshow(pktFrag.isFirst),
            //     ", pktFrag.isLast=", fshow(pktFrag.isLast)
            // );
        end
        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestSendQueueNormalCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 10241;
    let genPayload = True;
    let result <- mkTestSendQueueNormalAndNoPayloadCase(
        genPayload, minDmaLength, maxDmaLength
    );
endmodule

(* doc = "testcase" *)
module mkTestSendQueueNoPayloadCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 10241;
    let genPayload = False;
    let result <- mkTestSendQueueNormalAndNoPayloadCase(
        genPayload, minDmaLength, maxDmaLength
    );
endmodule

(* doc = "testcase" *)
module mkTestSendQueueZeroPayloadLenCase(Empty);
    let minDmaLength = 0;
    let maxDmaLength = 0;
    let genPayload = True;
    let result <- mkTestSendQueueNormalAndNoPayloadCase(
        genPayload, minDmaLength, maxDmaLength
    );
endmodule

module mkTestSendQueueNormalAndNoPayloadCase#(
    Bool genPayload, Length minDmaLength, Length maxDmaLength
)(Empty);
    Reg#(Bool) clearReg <- mkReg(True);

    // WQE generation
    Vector#(2, PipeOut#(WorkQueueElem)) wqePipeOutVec <- genPayload ?
        mkRandomWorkQueueElemWithPayload(minDmaLength, maxDmaLength) :
        mkRandomWorkQueueElemWithOutPayload(minDmaLength, maxDmaLength);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(clearReg, dmaReadCntrl);

    let dut <- mkSendQ(clearReg, payloadGenerator);
    mkConnection(dut.srvPort.request, toGet(wqePipeOutVec[0]));
    let wqePipeOut4Ref <- mkBufferN(getMaxFragBufSize, wqePipeOutVec[1]);

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        dut.rdmaDataStreamPipeOut
    );
    // Convert header DataStream to HeaderRDMA
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );

    let udpInfoPipeOut4Ref <- mkBufferN(getMaxFragBufSize, dut.udpInfoPipeOut);
    FIFOF#(Tuple2#(HeaderByteNum, MAC)) headerLenAndMacAddrQ <- mkFIFOF;

    Reg#(PktLen) payloadLenReg <- mkRegU;
    Reg#(PSN)    curPsnReg <- mkRegU;
    Reg#(Bool) psnIsValidReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(wqePipeOut4Ref);
    // mkSink(dut.udpInfoPipeOut);
    // mkSink(dut.rdmaDataStreamPipeOut);
    // mkSink(rdmaHeaderPipeOut);
    // mkSink(toPipeOut(headerLenAndMacAddrQ));
    // mkSink(headerAndMetaDataAndPayloadPipeOut.payload);
    // mkSink(udpInfoPipeOut4Ref);
    // rule discardSendResp if (!clearReg);
    //     let sendResp <- dut.srvPort.response.get;
    //     $display("time=%0t: discardSendResp", $time);
    // endrule

    rule clearAll if (clearReg);
        clearReg <= False;
        psnIsValidReg <= False;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule compareRdmaReqHeader if (!clearReg);
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth  = extractBTH(rdmaHeader.headerData);
        let reth = extractRETH(rdmaHeader.headerData, transType);
        let leth = extractLETH(rdmaHeader.headerData, transType);
        // $display("time=%0t: BTH=", $time, fshow(bth));

        if (psnIsValidReg) begin
            curPsnReg <= curPsnReg + 1;

            immAssert(
                bth.psn == curPsnReg,
                "bth.psn correctness assertion @ mkTestSendQueueNormalAndNoPayloadCase",
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
            let sendResp <- dut.srvPort.response.get;
            wqePipeOut4Ref.deq;
            psnIsValidReg <= False;

            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn read request packet assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                $format(
                    "bth.psn=%h should == wrStartPSN=%h when refWQE.opcode=",
                    bth.psn, wrStartPSN, fshow(refWQE.opcode)
                )
            );
            let isReadWR = isReadWorkReq(refWQE.opcode);
            if (isReadWR) begin
                let firstIdxSGE = 0;
                immAssert(
                    // TODO: enable LETH check after update calcHeaderLenByTransTypeAndRdmaOpCode()
                    reth.rkey == refWQE.rkey && reth.va == refWQE.raddr,
                    // leth.lkey  == refWQE.sgl[firstIdxSGE].lkey  &&
                    // leth.va    == refWQE.sgl[firstIdxSGE].laddr &&
                    // leth.dlen  == refWQE.sgl[firstIdxSGE].len,
                    "read request assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                    $format(
                        "reth.rkey=%h should == refWQE.rkey=%h", reth.rkey, refWQE.rkey,
                        ", reth.va=%h should == refWQE.raddr=%h", reth.va, refWQE.raddr,
                        ", leth.lkey=%h should == refWQE.sgl[0].lkey=%h", leth.lkey, refWQE.sgl[firstIdxSGE].lkey,
                        ", leth.va=%h should == refWQE.sgl[0].laddr=%h", leth.va, refWQE.sgl[firstIdxSGE].laddr,
                        ", leth.dlen=%0d should == refWQE.sgl[0].len=%0d", leth.dlen, refWQE.sgl[firstIdxSGE].len,
                        ", when refWQE.opcode=", fshow(refWQE.opcode)
                    )
                );
                // $display(
                //     "time=%0t: check read request", $time,
                //     ", RETH=", fshow(reth),
                //     ", LETH=", fshow(leth),
                //     ", refWQE=", fshow(refWQE)
                // );
            end
        end
        else if (isLastRdmaOpCode(rdmaOpCode)) begin
            let sendResp <- dut.srvPort.response.get;
            wqePipeOut4Ref.deq;
            psnIsValidReg <= False;
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            psnIsValidReg <= True;

            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn first request packet assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            immAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle request packet assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA request opcode"
                )
            );
        end

        let isRecvSide = True;
        immAssert(
            transTypeMatchQpType(transType, refWQE.qpType, isRecvSide),
            "transTypeMatchQpType assertion @ mkTestSendQueueNormalAndNoPayloadCase",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(refWQE.qpType),
                " and isRecvSide=", fshow(isRecvSide)
            )
        );
        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, refWQE.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestSendQueueNormalAndNoPayloadCase",
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
            "maybePktFragLen assertion @ mkTestSendQueueNormalAndNoPayloadCase",
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
                "macAddr assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                $format(
                    "udpPktInfo.macAddr=%h shoud == expectedMacAddr=%h",
                    udpPktInfo.macAddr, expectedMacAddr
                )
            );

            immAssert(
                udpPktInfo.pktLen == totalPayloadLen + zeroExtend(headerLen),
                "udpPktInfo.pktLen assertion @ mkTestSendQueueNormalAndNoPayloadCase",
                $format(
                    "udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
                    " should == totalPayloadLen=%0d", totalPayloadLen,
                    " + headerLen=%0d", headerLen
                )
            );
            // $display(
            //     "time=%0t: checkPktLen", $time,
            //     ", udpPktInfo.pktLen=%0d", udpPktInfo.pktLen,
            //     ", totalPayloadLen=%0d", totalPayloadLen,
            //     ", headerLen=%0d", headerLen,
            //     ", udpPktInfo.macAddr=%h", udpPktInfo.macAddr,
            //     ", udpPktInfo.ipAddr=", fshow(udpPktInfo.ipAddr)
            // );
        end
    endrule
endmodule
