import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import InputPktHandle :: *;
import Headers :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import ReqGenSQ :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

(* doc = "testcase" *)
module mkTestReqGenNormalCase(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 10241;
    let result <- mkTestReqGenNormalAndZeroLenCase(minDmaLength, maxDmaLength);
endmodule

(* doc = "testcase" *)
module mkTestReqGenZeroLenCase(Empty);
    let minDmaLength = 0;
    let maxDmaLength = 0;
    let result <- mkTestReqGenNormalAndZeroLenCase(minDmaLength, maxDmaLength);
endmodule

module mkTestReqGenNormalAndZeroLenCase#(
    Length minDmaLength, Length maxDmaLength
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    // WorkReq generation
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let newPendingWorkReqPipeOut =
        genNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);
    let workReqPipeOut4Ref <- mkBufferN(2, workReqPipeOutVec[1]);

    // Request payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let dataStreamWithPaddingPipeOut <- mkDataStreamAddPadding(
        simDmaReadSrv.dataStream
    );
    let dataStreamWithPaddingPipeOut4Ref <- mkBufferN(getMaxFragBufSize, dataStreamWithPaddingPipeOut);

    let pendingWorkReqBufNotEmpty = True;
    let dmaReadCntrl <- mkDmaReadCntrl(
        cntrlStatus, simDmaReadSrv.dmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );
    // DUT
    let reqGenSQ <- mkReqGenSQ(
        cntrl.contextSQ,
        payloadGenerator,
        newPendingWorkReqPipeOut,
        pendingWorkReqBufNotEmpty
    );
    Vector#(2, PipeOut#(PendingWorkReq)) pendingWorkReqPipeOutVec <-
        mkForkVector(reqGenSQ.pendingWorkReqPipeOut);
    let pendingWorkReqPipeOut4Comp = pendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Ref <- mkBufferN(2, pendingWorkReqPipeOutVec[1]);
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    // No error WC when normal case
    let errWorkCompGenReqPipeOut = reqGenSQ.workCompGenReqPipeOut;
    let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        errWorkCompGenReqPipeOut,
        "errWorkCompGenReqPipeOut empty assertion @ mkTestReqGenNormalCase"
    ));

    // Extract header DataStream, HeaderMetaData and payload DataStream
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqPipeOut
    );
    // Convert header DataStream to RdmaHeader
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );
    // Remove empty payload DataStream
    let filteredPayloadDataStreamPipeOut <- mkPipeFilter(
        filterEmptyDataStream,
        headerAndMetaDataAndPayloadPipeOut.payload
    );

    Reg#(PSN)    curPsnReg <- mkRegU;
    Reg#(Bool) validPsnReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4Comp);
    // mkSink(workReqPipeOut4Ref);
    // mkSink(rdmaHeaderPipeOut);
    // mkSink(pendingWorkReqPipeOut4Ref);
    // mkSink(filteredPayloadDataStreamPipeOut);
    // mkSink(dataStreamWithPaddingPipeOut4Ref);

    rule compareWorkReq;
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        immAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestReqGenNormalCase",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );
        // $display("time=%0t: WR=", $time, fshow(pendingWR.wr));
    endrule

    rule compareRdmaReqHeader;
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        $display("time=%0t: BTH=", $time, fshow(bth));

        if (validPsnReg) begin
            curPsnReg <= curPsnReg + 1;

            immAssert(
                bth.psn == curPsnReg,
                "bth.psn correctness assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == curPsnReg=%h", bth.psn, curPsnReg)
            );
        end
        else begin
            curPsnReg <= bth.psn + 1;
        end

        let refPendingWR = pendingWorkReqPipeOut4Ref.first;
        let wrStartPSN = unwrapMaybe(refPendingWR.startPSN);
        let wrEndPSN = unwrapMaybe(refPendingWR.endPSN);

        if (isOnlyRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            let isReadWR = isReadWorkReq(refPendingWR.wr.opcode);
            if (isReadWR) begin
                immAssert(
                    bth.psn == wrStartPSN,
                    "bth.psn read request packet assertion @ mkTestReqGenNormalCase",
                    $format(
                        "bth.psn=%h should == wrStartPSN=%h when refPendingWR.wr.opcode=",
                        bth.psn, wrStartPSN, fshow(refPendingWR.wr.opcode)
                    )
                );
            end
            else begin
                immAssert(
                    bth.psn == wrStartPSN && bth.psn == wrEndPSN,
                    "bth.psn only request packet assertion @ mkTestReqGenNormalCase",
                    $format(
                        "bth.psn=%h should == wrStartPSN=%h and bth.psn=%h should == wrEndPSN=%h",
                        bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                        ", when refPendingWR.wr.opcode=",
                        fshow(refPendingWR.wr.opcode)
                    )
                );
            end
        end
        else if (isLastRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            immAssert(
                bth.psn == wrEndPSN,
                "bth.psn last request packet assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == wrEndPSN=%h", bth.psn, wrEndPSN)
            );
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            immAssert(
                bth.psn == wrStartPSN,
                "bth.psn first request packet assertion @ mkTestReqGenNormalCase",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            immAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle request packet assertion @ mkTestReqGenNormalCase",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA request opcode"
                )
            );
            immAssert(
                psnInRangeExclusive(bth.psn, wrStartPSN, wrEndPSN),
                "bth.psn between wrStartPSN and wrEndPSN assertion @ mkTestReqGenNormalCase",
                $format(
                    "bth.psn=%h should > wrStartPSN=%h and bth.psn=%h should < wrEndPSN=%h",
                    bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                    ", when refPendingWR.wr.opcode=", fshow(refPendingWR.wr.opcode),
                    " and rdmaOpCode=", fshow(rdmaOpCode)
                )
            );
        end

        let isRespPkt = True;
        immAssert(
            transTypeMatchQpType(transType, qpType, isRespPkt),
            "transTypeMatchQpType assertion @ mkTestReqGenNormalCase",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(qpType),
                " and isRespPkt=", fshow(isRespPkt)
            )
        );
        immAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, refPendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestReqGenNormalCase",
            $format(
                "RDMA request opcode=", fshow(rdmaOpCode),
                " should match workReqOpCode=", fshow(refPendingWR.wr.opcode)
            )
        );

        // It must compare header not payload,
        // since WR might have zero length
        countDown.decr;
    endrule

    rule compareRdmaReqPayload;
        let payloadDataStream = filteredPayloadDataStreamPipeOut.first;
        filteredPayloadDataStreamPipeOut.deq;

        let refDataStream = dataStreamWithPaddingPipeOut4Ref.first;
        dataStreamWithPaddingPipeOut4Ref.deq;

        immAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestReqGenNormalCase",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestReqGenDmaReadErrCase(Empty);
    let minDmaLength = 1024;
    let maxDmaLength = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);
    Reg#(Bool) genErrWorkCompReg[2] <- mkCReg(2, False);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let workReqPipeOut4Dut = workReqPipeOutVec[0];
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec4Dut <-
        mkForkVector(workReqPipeOut4Dut);
    let newPendingWorkReqPipeOut =
        genNewPendingWorkReqPipeOut(workReqPipeOutVec4Dut[0]);
    let workReqPipeOut4Ref = workReqPipeOutVec4Dut[1];

    // Request payload DataStream generation
    let hasDmaReadRespErr = True;
    let minErrLen = 512;
    let maxErrLen = 1024;
    let simDmaReadSrv <- mkSimDmaReadSrvWithErr(
        hasDmaReadRespErr, minErrLen, maxErrLen
    );

    let pendingWorkReqBufNotEmpty = True;
    let dmaReadCntrl <- mkDmaReadCntrl(
        cntrlStatus, simDmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );
    // DUT
    let reqGenSQ <- mkReqGenSQ(
        cntrl.contextSQ,
        payloadGenerator,
        newPendingWorkReqPipeOut,
        pendingWorkReqBufNotEmpty
    );
    let pendingWorkReqPipeOut4Comp = reqGenSQ.pendingWorkReqPipeOut;
    let rdmaReqPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    mkSink(rdmaReqPipeOut);

    // Error WC
    let errWorkCompGenReqPipeOut = reqGenSQ.workCompGenReqPipeOut;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule checkErrWorkComp;
        if (genErrWorkCompReg[0]) begin
            immAssert(
                !errWorkCompGenReqPipeOut.notEmpty,
                "errWorkCompGenReqPipeOut empty assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "errWorkCompGenReqPipeOut.notEmpty=",
                    fshow(errWorkCompGenReqPipeOut.notEmpty),
                    " should be false"
                )
            );

            countDown.decr;
        end
        else begin
            let errWorkCompReq = errWorkCompGenReqPipeOut.first;
            errWorkCompGenReqPipeOut.deq;

            genErrWorkCompReg[0] <= True;

            immAssert(
                errWorkCompReq.wcStatus == IBV_WC_LOC_QP_OP_ERR,
                "errWorkCompReq status assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "errWorkCompReq.wcStatus=", fshow(errWorkCompReq.wcStatus),
                    " should be IBV_WC_LOC_QP_OP_ERR"
                )
            );

            // $display(
            //     "time=%0t: checkErrWorkComp", $time,
            //     ", error WC request=", fshow(errWorkCompReq)
            // );
        end
    endrule

    rule compareWorkReq;
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        immAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestReqGenDmaReadErrCase",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );

        if (genErrWorkCompReg[1]) begin
            immAssert(
                !isValid(pendingWR.startPSN) &&
                !isValid(pendingWR.endPSN)   &&
                !isValid(pendingWR.pktNum)   &&
                !isValid(pendingWR.isOnlyReqPkt),
                "pendingWR invalid assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "pendingWR should have invalid PSN and PktNum when error flushing, pendingWR=",
                    fshow(pendingWR)
                )
            );
        end
        else begin
            immAssert(
                isValid(pendingWR.startPSN) &&
                isValid(pendingWR.endPSN)   &&
                isValid(pendingWR.pktNum)   &&
                isValid(pendingWR.isOnlyReqPkt),
                "pendingWR valid assertion @ mkTestReqGenDmaReadErrCase",
                $format(
                    "pendingWR should have valid PSN and PktNum before error flushing, pendingWR=",
                    fshow(pendingWR)
                )
            );
        end
        // $display(
        //     "time=%0t: compareWorkReq", $time,
        //     ", genErrWorkCompReg[1]=", genErrWorkCompReg[1],
        //     ", pendingWR=", fshow(pendingWR)
        // );
    endrule
endmodule
