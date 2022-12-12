import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import InputPktHandle :: *;
import Headers :: *;
import ReqGenSQ :: *;
import Settings :: *;
import SimDma :: *;
import Utils4Test :: *;
import Utils :: *;

// TODO: test zero length WR case
(* synthesize *)
module mkTestReqGenSQ(Empty);
    let minDmaLength = 128;
    let maxDmaLength = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimController(qpType, pmtu);

    // WorkReq generation
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let newPendingWorkReqPipeOut <-
        mkNewPendingWorkReqPipeOut(workReqPipeOutVec[0]);
    let workReqPipeOut4Ref <- mkBufferN(4, workReqPipeOutVec[1]);

    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let segDataStreamPipeOut <- mkSegmentDataStreamByPmtu(
        simDmaReadSrv.dataStreamPipeOut, pmtu
    );
    let segDataStreamPipeOut4Ref <- mkBufferN(4, segDataStreamPipeOut);

    // DUT
    let workReq2RdmaReq <- mkWorkReq2RdmaReq(
        cntrl, simDmaReadSrv.dmaReadSrv, newPendingWorkReqPipeOut
    );
    Vector#(2, PipeOut#(PendingWorkReq)) pendingWorkReqPipeOutVec <-
        mkForkVector(workReq2RdmaReq.pendingWorkReq);
    let pendingWorkReqPipeOut4Comp = pendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Ref <- mkBufferN(2, pendingWorkReqPipeOutVec[1]);
    let rdmaReqPipeOut = workReq2RdmaReq.rdmaReq;

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

    rule compareWorkReq;
        let pendingWR = pendingWorkReqPipeOut4Comp.first;
        pendingWorkReqPipeOut4Comp.deq;

        let refWorkReq = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        dynAssert(
            pendingWR.wr.id == refWorkReq.id &&
            pendingWR.wr.opcode == refWorkReq.opcode,
            "pendingWR.wr assertion @ mkTestReqGenSQ",
            $format(
                "pendingWR.wr=", fshow(pendingWR.wr),
                " should == refWorkReq=", fshow(refWorkReq)
            )
        );
        // $display("time=%0d: WR=", $time, fshow(pendingWR.wr));
    endrule

    rule compareRdmaReqHeader;
        let rdmaHeader = rdmaHeaderPipeOut.first;
        rdmaHeaderPipeOut.deq;

        let { transType, rdmaOpCode } =
            extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
        let bth = extractBTH(rdmaHeader.headerData);
        // $display("time=%0d: BTH=", $time, fshow(bth));

        if (validPsnReg) begin
            curPsnReg <= curPsnReg + 1;

            dynAssert(
                bth.psn == curPsnReg,
                "bth.psn correctness assertion @ mkTestReqGenSQ",
                $format("bth.psn=%h shoud == curPsnReg=%h", bth.psn, curPsnReg)
            );
        end
        else begin
            curPsnReg <= bth.psn + 1;
        end

        let refPendingWR = pendingWorkReqPipeOut4Ref.first;
        let wrStartPSN = fromMaybe(?, refPendingWR.startPSN);
        let wrEndPSN = fromMaybe(?, refPendingWR.endPSN);

        if (isOnlyRdmaOpCode(rdmaOpCode)) begin
            pendingWorkReqPipeOut4Ref.deq;

            let isReadWR = isReadWorkReq(refPendingWR.wr.opcode);
            if (isReadWR) begin
                dynAssert(
                    bth.psn == wrStartPSN,
                    "bth.psn read request packet assertion @ mkTestReqGenSQ",
                    $format(
                        "bth.psn=%h should == wrStartPSN=%h when refPendingWR.wr.opcode=",
                        bth.psn, wrStartPSN, fshow(refPendingWR.wr.opcode)
                    )
                );
            end
            else begin
                dynAssert(
                    bth.psn == wrStartPSN && bth.psn == wrEndPSN,
                    "bth.psn only request packet assertion @ mkTestReqGenSQ",
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

            dynAssert(
                bth.psn == wrEndPSN,
                "bth.psn last request packet assertion @ mkTestReqGenSQ",
                $format("bth.psn=%h shoud == wrEndPSN=%h", bth.psn, wrEndPSN)
            );
        end
        else if (isFirstRdmaOpCode(rdmaOpCode)) begin
            dynAssert(
                bth.psn == wrStartPSN,
                "bth.psn first request packet assertion @ mkTestReqGenSQ",
                $format("bth.psn=%h shoud == wrStartPSN=%h", bth.psn, wrStartPSN)
            );
        end
        else begin
            dynAssert(
                isMiddleRdmaOpCode(rdmaOpCode),
                "rdmaOpCode middle request packet assertion @ mkTestReqGenSQ",
                $format(
                    "rdmaOpCode=", fshow(rdmaOpCode), " should be middle RDMA request opcode"
                )
            );
            dynAssert(
                psnInRangeExclusive(bth.psn, wrStartPSN, wrEndPSN),
                "bth.psn between wrStartPSN and wrEndPSN assertion @ mkTestReqGenSQ",
                $format(
                    "bth.psn=%h should > wrStartPSN=%h and bth.psn=%h should < wrEndPSN=%h",
                    bth.psn, wrStartPSN, bth.psn, wrEndPSN,
                    ", when refPendingWR.wr.opcode=", fshow(refPendingWR.wr.opcode),
                    " and rdmaOpCode=", fshow(rdmaOpCode)
                )
            );
        end

        dynAssert(
            transTypeMatchQpType(transType, qpType),
            "transTypeMatchQpType assertion @ mkTestReqGenSQ",
            $format(
                "transType=", fshow(transType),
                " should match qpType=", fshow(qpType)
            )
        );
        dynAssert(
            rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, refPendingWR.wr.opcode),
            "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestReqGenSQ",
            $format(
                "RDMA request opcode=", fshow(rdmaOpCode),
                " should match workReqOpCode=", fshow(refPendingWR.wr.opcode)
            )
        );
    endrule

    rule compareRdmaReqPayload;
        let payloadDataStream = filteredPayloadDataStreamPipeOut.first;
        filteredPayloadDataStreamPipeOut.deq;

        let refDataStream = segDataStreamPipeOut4Ref.first;
        segDataStreamPipeOut4Ref.deq;

        if (refDataStream.isLast) begin
            let lastFragValidByteNum = calcByteEnBitNumInSim(refDataStream.byteEn);
            let padCnt = calcPadCnt(zeroExtend(lastFragValidByteNum));
            let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
            let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);

            // $display(
            //     "time=%0d: refDataStream.byteEn=%h, padCnt=%0d",
            //     $time, refDataStream.byteEn, padCnt
            // );
            refDataStream.byteEn = lastFragByteEnWithPadding;
        end
        dynAssert(
            payloadDataStream == refDataStream,
            "payloadDataStream assertion @ mkTestReqGenSQ",
            $format(
                "payloadDataStream=", fshow(payloadDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );
    endrule
endmodule
