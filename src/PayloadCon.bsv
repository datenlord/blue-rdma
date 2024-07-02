import BRAMFIFO :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;
import Probe :: *;

import Settings :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import RdmaUtils :: *;

interface BramPipe#(type anytype);
    interface PipeOut#(anytype) pipeOut;
    method Action clear();
    method Bool notEmpty();
endinterface

module mkConnectBramQ2PipeOut#(FIFOF#(anytype) bramQ)(
    BramPipe#(anytype)
) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(postBramQ), toGet(bramQ));

    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

module mkConnectPipeOut2BramQ#(
    PipeOut#(anytype) pipeIn, FIFOF#(anytype) bramQ
)(BramPipe#(anytype)) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(bramQ), toGet(pipeIn));
    mkConnection(toPut(postBramQ), toGet(bramQ));

    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

function Bool isDiscardPayload(PayloadConInfo payloadConInfo);
    return case (payloadConInfo) matches
        tagged DiscardPayloadInfo .info: True;
        default                        : False;
    endcase;
endfunction

interface PayloadConsumer;
    interface Server#(PayloadConReq, PayloadConResp) controlPortSrv;
    interface DmaWriteClt dmaWriteClt;
    interface DataStreamFragMetaPipeIn payloadStreamFragMetaPipeIn;
    interface Client#(Tuple2#(InputStreamFragBufferIdx, Bool), DATA) readFragClt;
endinterface

// Flush DMA write responses when error
module mkPayloadConsumer(PayloadConsumer);

    BypassServer#(PayloadConReq, PayloadConResp) controlPortSrvInst <- mkBypassServer("controlPortSrvInst");
    BypassClient#(DmaWriteReq, DmaWriteResp) dmaWriteCltInst <- mkBypassClient("dmaWriteCltInst");
    FIFOF#(DataStreamFragMetaData) payloadFragMetaInBufQ <- mkFIFOF;
    BypassClient#(Tuple2#(InputStreamFragBufferIdx, Bool), DATA) readFragCltInst <- mkBypassClient("readFragCltInst");

    // Pipeline FIFO
    FIFOF#(Tuple3#(PayloadConReq, Bool, Bool))                    countReqFragQ <- mkFIFOF;
    FIFOF#(Tuple4#(PayloadConReq, Bool, Bool, Bool))             pendingConReqQ <- mkFIFOF;
    FIFOF#(PayloadConReq)                                           genConRespQ <- mkSizedFIFOF(valueOf(DMA_WRITE_INFLIGHT_QUEUE_LENGTH));
    FIFOF#(Tuple2#(PayloadConReq, DataStreamFragMetaData))       pendingDmaReqQ <- mkSizedFIFOF(6);


    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStreamFragMetaData) payloadFragMetaBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let pipeOut2Bram <- mkConnectPipeOut2BramQ(toPipeOut(payloadFragMetaInBufQ), payloadFragMetaBufQ);
    let payloadBufPipeOut = pipeOut2Bram.pipeOut;

    Reg#(PktFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool) isRemainingFragNumZeroReg <- mkReg(False);
    Reg#(Bool)      isFirstOrOnlyFragReg <- mkReg(True);

    Reg#(Bit#(4)) queueFullDebugReg <- mkReg(-1);
    Probe#(Bit#(4)) queueFullDebugProbe <- mkProbe;
    rule debugFillQueueFullDebugReg;
        queueFullDebugReg <= queueFullDebugReg & {
            pack(countReqFragQ.notFull),
            pack(pendingConReqQ.notFull),
            pack(genConRespQ.notFull),
            pack(pendingDmaReqQ.notFull)
        };
        queueFullDebugProbe <= queueFullDebugReg;
    endrule

    function Action checkIsOnlyPayloadFragment(
        DataStreamFragMetaData payloadFragMeta, PayloadConInfo consumeInfo
    );
        action
            immAssert(
                payloadFragMeta.isFirst && payloadFragMeta.isLast,
                "only payloadFragMeta assertion @ mkPayloadConsumer",
                $format(
                    "payloadFragMeta.isFirst=", fshow(payloadFragMeta.isFirst),
                    "and payloadFragMeta.isLast=", fshow(payloadFragMeta.isLast),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    rule debug;
        if (!countReqFragQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: countReqFragQ");
        end
        if (!pendingConReqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: pendingConReqQ");
        end
        if (!genConRespQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: genConRespQ");
        end
        if (!pendingDmaReqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: pendingDmaReqQ");
        end
        if (!payloadFragMetaBufQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaBufQ");
        end
        
        // if (!payloadBufPipeOut.notEmpty) begin
        //     $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: payloadBufPipeOut");
        // end
        
    endrule


    rule recvReq;
        let consumeReq <- controlPortSrvInst.getReq;

        let isDiscardReq = False;
        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                isDiscardReq = True;

                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is DiscardPayload",
                        consumeReq.fragNum
                    )
                );
            end
            tagged WriteReqInfo .writeReqInfo    : begin
                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is WriteReqInfo",
                        consumeReq.fragNum
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        let isFragNumLessOrEqOne = isLessOrEqOne(consumeReq.fragNum);
        countReqFragQ.enq(tuple3(consumeReq, isFragNumLessOrEqOne, isDiscardReq));
        $display(
            "time=%0t: PayloadConsumer recvReq", $time,
            ", consumeReq=", fshow(consumeReq)
        );
    endrule

    rule countReqFrag;
        let { consumeReq, isFragNumLessOrEqOne, isDiscardReq } = countReqFragQ.first;

        let isLastReqFrag = isFragNumLessOrEqOne ? True : isRemainingFragNumZeroReg;

        if (isDiscardReq) begin
            countReqFragQ.deq;
        end
        else begin
            if (isLastReqFrag) begin
                countReqFragQ.deq;
                isFirstOrOnlyFragReg      <= True;
                isRemainingFragNumZeroReg <= False;
            end
            else begin
                if (isFirstOrOnlyFragReg) begin
                    remainingFragNumReg       <= consumeReq.fragNum - 2;
                    isRemainingFragNumZeroReg <= isTwo(consumeReq.fragNum);
                    isFirstOrOnlyFragReg      <= False;
                end
                else begin
                    remainingFragNumReg       <= remainingFragNumReg - 1;
                    isRemainingFragNumZeroReg <= isOne(remainingFragNumReg);
                end
            end
        end

        pendingConReqQ.enq(tuple4(
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFragReg, isLastReqFrag
        ));
        $display(
            "time=%0t: countReqFrag", $time,
            ", consumeReq.fragNum=%0d", consumeReq.fragNum,
            ", remainingFragNumReg=%0d", remainingFragNumReg,
            ", isRemainingFragNumZeroReg=", fshow(isRemainingFragNumZeroReg),
            ", isFirstOrOnlyFragReg=", fshow(isFirstOrOnlyFragReg),
            ", isLastReqFrag=", fshow(isLastReqFrag)
        );
    endrule

    rule consumePayload;
        let {
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFrag, isLastReqFrag
        } = pendingConReqQ.first;
        let shouldDeqConReq = True;
        // pendingConReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                let payloadFragMeta = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;
                shouldDeqConReq = payloadFragMeta.isLast;
                let isOnlyUpadteFragBufLastConsumeIndex = True;
                readFragCltInst.putReq(tuple2(payloadFragMeta.bufIdx, isOnlyUpadteFragBufLastConsumeIndex));
            end
            tagged WriteReqInfo .writeReqInfo: begin
                let payloadFragMeta = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;
                $display(
                    "time=%0t: consumePayload", $time,
                    ", payloadFragMeta=", fshow(payloadFragMeta)
                );
                if (isFragNumLessOrEqOne) begin
                    checkIsOnlyPayloadFragment(payloadFragMeta, consumeReq.consumeInfo);
                    $display(
                        "time=%0t: single packet response consumeReq.fragNum=%0d",
                        $time, consumeReq.fragNum
                    );
                end
                $display(
                    "time=%0t: WriteReqInfo", $time,
                    ", consumeReq=", fshow(consumeReq),
                    ", isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                    ", isLastReqFrag=", fshow(isLastReqFrag),
                    ", payloadFragMeta.isFirst=", fshow(payloadFragMeta.isFirst),
                    ", payloadFragMeta.isLast=", fshow(payloadFragMeta.isLast)
                );

                if (isFirstOrOnlyFrag) begin
                    immAssert(
                        payloadFragMeta.isFirst,
                        "first payloadFragMeta assertion @ mkPayloadConsumer",
                        $format(
                            "payloadFragMeta.isFirst=", fshow(payloadFragMeta.isFirst),
                            " should be true when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end
                else begin
                    immAssert(
                        !payloadFragMeta.isFirst,
                        "first payloadFragMeta assertion @ mkPayloadConsumer",
                        $format(
                            "payloadFragMeta.isFirst=", fshow(payloadFragMeta.isFirst),
                            " should be false when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end

                if (isLastReqFrag) begin
                    immAssert(
                        payloadFragMeta.isLast,
                        "last payloadFragMeta assertion @ mkPayloadConsumer",
                        $format(
                            "payloadFragMeta.isLast=", fshow(payloadFragMeta.isLast),
                            " should be true when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );

                    genConRespQ.enq(consumeReq);
                end
                else begin
                    immAssert(
                        !payloadFragMeta.isLast,
                        "last payloadFragMeta assertion @ mkPayloadConsumer",
                        $format(
                            "payloadFragMeta.isLast=", fshow(payloadFragMeta.isLast),
                            " should be false when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end
                let isOnlyUpadteFragBufLastConsumeIndex = False;
                readFragCltInst.putReq(tuple2(payloadFragMeta.bufIdx, isOnlyUpadteFragBufLastConsumeIndex));
                pendingDmaReqQ.enq(tuple2(consumeReq, payloadFragMeta));
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        if (shouldDeqConReq) begin
            pendingConReqQ.deq;
        end
    endrule

    rule issueDmaReq;
        let { consumeReq, payloadFragMeta } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;
        let payloadData <- readFragCltInst.getResp;

        case (consumeReq.consumeInfo) matches
            tagged WriteReqInfo .writeReqInfo: begin
                let dmaWriteReq = DmaWriteReq {
                    metaData  : writeReqInfo,
                    dataStream: DataStream {
                        isFirst: payloadFragMeta.isFirst,
                        isLast: payloadFragMeta.isLast,
                        byteNum: payloadFragMeta.byteNum,
                        data: payloadData
                    }
                };
                $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));
                dmaWriteCltInst.putReq(dmaWriteReq);
            end
            default: begin
                immAssert(
                    isDiscardPayload(consumeReq.consumeInfo),
                    "isDiscardPayload assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo),
                        " should be DiscardPayload"
                    )
                );
            end
        endcase
    endrule

    rule genConResp;
        let dmaWriteResp <- dmaWriteCltInst.getResp;
        let consumeReq = genConRespQ.first;
        genConRespQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged WriteReqInfo .writeReqInfo: begin
                let consumeResp = PayloadConResp {
                    dmaWriteResp : DmaWriteResp {
                        isRespErr: dmaWriteResp.isRespErr
                    }
                };
                controlPortSrvInst.putResp(consumeResp);
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase
        $display(
            "time=%0t: genConResp", $time,
            ", dmaWriteResp=", fshow(dmaWriteResp),
            ", consumeReq=", fshow(consumeReq)
        );
    endrule

    interface controlPortSrv = controlPortSrvInst.srv;
    interface dmaWriteClt = dmaWriteCltInst.clt;
    interface payloadStreamFragMetaPipeIn = toPut(payloadFragMetaInBufQ);
    interface readFragClt = readFragCltInst.clt;
endmodule
