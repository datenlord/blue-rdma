import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Utils :: *;

// interface Server#(type req_type, type resp_type);
//     interface Put#(req_type) request;
//     interface Get#(resp_type) response;
// endinterface: Server

function DataStream getDataStreamFromPayloadGenRespPipeOut(
    PayloadGenResp resp
) = resp.dmaReadResp.data;

interface PayloadGenerator;
    method Action request(PayloadGenReq req);
    interface PipeOut#(PayloadGenResp) respPipeOut;
endinterface

module mkPayloadGenerator#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv
)(PayloadGenerator);
    FIFOF#(PayloadGenResp)                generateRespQ <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadGenReq, ByteEn)) generateReqQ <- mkFIFOF;

    rule generatePayload if (cntrl.isRTRorRTS);
        let dmaReadResp <- dmaReadSrv.response.get;
        let { generateReq, lastFragByteEnWithPadding } = generateReqQ.first;

        if (dmaReadResp.data.isLast) begin
            generateReqQ.deq;

            if (generateReq.addPadding) begin
                dmaReadResp.data.byteEn = lastFragByteEnWithPadding;
            end
        end

        let generateResp = PayloadGenResp {
            initiator  : generateReq.initiator,
            addPadding : generateReq.addPadding,
            dmaReadResp: dmaReadResp
        };
        generateRespQ.enq(generateResp);
    endrule

    rule flushDmaReadResp if (cntrl.isERR);
        let dmaReadResp <- dmaReadSrv.response.get;
    endrule

    rule flushReqRespQ if (cntrl.isERR);
        generateReqQ.clear;
        generateRespQ.clear;
    endrule

    method Action request(PayloadGenReq generateReq) if (cntrl.isRTRorRTS);
        dynAssert(
            !isZero(generateReq.dmaReadReq.len),
            "generateReq.dmaReadReq.len assertion @ mkPayloadGenerator",
            $format(
                "generateReq.dmaReadReq.len=%0d should not be zero",
                generateReq.dmaReadReq.len
            )
        );
        let dmaLen = generateReq.dmaReadReq.len;
        let padCnt = calcPadCnt(dmaLen);
        let lastFragValidByteNum = calcLastFragValidByteNum(dmaLen);
        let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
        let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
        dynAssert(
            !isZero(lastFragValidByteNumWithPadding),
            "lastFragValidByteNumWithPadding assertion @ mkPayloadGenerator",
            $format(
                "lastFragValidByteNumWithPadding=%0d should not be zero",
                lastFragValidByteNumWithPadding,
                ", dmaLen=%0d, lastFragValidByteNum=%0d, padCnt=%0d",
                dmaLen, lastFragValidByteNum, padCnt
            )
        );

        generateReqQ.enq(tuple2(generateReq, lastFragByteEnWithPadding));
        dmaReadSrv.request.put(generateReq.dmaReadReq);
    endmethod

    interface respPipeOut = convertFifo2PipeOut(generateRespQ);
endmodule

interface PayloadConsumer;
    // method Action request(PayloadConReq req);
    interface PipeOut#(PayloadConResp) respPipeOut;
endinterface

// Flush DMA write responses when error
module mkPayloadConsumer#(
    Controller cntrl,
    DataStreamPipeOut payloadPipeIn,
    DmaWriteSrv dmaWriteSrv,
    PipeOut#(PayloadConReq) payloadConReqPipeIn
)(PayloadConsumer);
    FIFOF#(PayloadConReq)    consumeReqQ <- mkFIFOF;
    FIFOF#(PayloadConResp)  consumeRespQ <- mkFIFOF;
    FIFOF#(PayloadConReq) pendingConReqQ <- mkFIFOF;

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);

    function Action checkIsFirstPayloadDataStream(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            dynAssert(
                payload.isFirst,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    function Action checkIsOnlyPayloadDataStream(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            dynAssert(
                payload.isFirst && payload.isLast,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    "and payload.isLast=", fshow(payload.isLast),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    function Action sendDmaWriteReq(
        PayloadConReq consumeReq, DataStream payload
    );
        action
            case (consumeReq.consumeInfo) matches
                tagged ReadRespInfo .readRespInfo: begin
                    let dmaWriteReq = DmaWriteReq {
                        metaData: readRespInfo,
                        data    : payload
                    };
                    dmaWriteSrv.request.put(dmaWriteReq);
                end
                tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                    let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                    let dmaWriteReq = DmaWriteReq {
                        metaData: atomicRespDmaWriteMetaData,
                        data: DataStream {
                            data   : zeroExtendLSB(atomicRespPayload),
                            byteEn : genByteEn(fromInteger(valueOf(ATOMIC_WORK_REQ_LEN))),
                            isFirst: True,
                            isLast : True
                        }
                    };
                    dmaWriteSrv.request.put(dmaWriteReq);
                end
                default: begin end
            endcase
        endaction
    endfunction

    rule recvReq if (cntrl.isRTRorRTS);
        let consumeReq = payloadConReqPipeIn.first;
        payloadConReqPipeIn.deq;

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayload: begin
                dynAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is DiscardPayload",
                        consumeReq.fragNum
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                dynAssert(
                    atomicRespDmaWriteMetaData.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                    "atomicRespDmaWriteMetaData.len assertion @ mkPayloadConsumer",
                    $format(
                        "atomicRespDmaWriteMetaData.len=%h should be %h when consumeInfo is AtomicRespInfoAndPayload",
                        atomicRespDmaWriteMetaData.len, valueOf(ATOMIC_WORK_REQ_LEN)
                    )
                );
            end
            tagged ReadRespInfo .readRespInfo: begin
                dynAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is ReadRespPayload",
                        consumeReq.fragNum
                    )
                );
            end
            default: begin end
        endcase

        consumeReqQ.enq(consumeReq);
    endrule

    rule processReq if (cntrl.isRTRorRTS && !busyReg);
        let consumeReq = consumeReqQ.first;
        case (consumeReq.consumeInfo) matches
            tagged DiscardPayload: begin
                let payload = payloadPipeIn.first;
                payloadPipeIn.deq;

                if (isLessOrEqOne(consumeReq.fragNum)) begin
                    checkIsOnlyPayloadDataStream(payload, consumeReq.consumeInfo);
                    consumeReqQ.deq;
                    pendingConReqQ.enq(consumeReq);
                end
                else begin
                    remainingFragNumReg <= consumeReq.fragNum - 2;
                    busyReg <= True;
                end
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                consumeReqQ.deq;
                sendDmaWriteReq(consumeReq, dontCareValue);
            end
            tagged ReadRespInfo .readRespInfo: begin
                let payload = payloadPipeIn.first;
                payloadPipeIn.deq;
                if (isLessOrEqOne(consumeReq.fragNum)) begin
                    checkIsOnlyPayloadDataStream(payload, consumeReq.consumeInfo);
                    consumeReqQ.deq;
                    pendingConReqQ.enq(consumeReq);
                end
                else begin
                    checkIsFirstPayloadDataStream(payload, consumeReq.consumeInfo);
                    remainingFragNumReg <= consumeReq.fragNum - 2;
                    busyReg <= True;
                end

                sendDmaWriteReq(consumeReq, payload);
            end
            default: begin end
        endcase
    endrule

    rule consumePayload if (cntrl.isRTRorRTS && busyReg);
        let consumeReq = consumeReqQ.first;
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        remainingFragNumReg <= remainingFragNumReg - 1;
        if (isZero(remainingFragNumReg)) begin
            dynAssert(
                payload.isLast,
                "payload.isLast assertion @ mkPayloadConsumer",
                $format(
                    "payload.isLast=", fshow(payload.isLast),
                    " should be true when remainingFragNumReg=%h is zero",
                    remainingFragNumReg
                )
            );

            consumeReqQ.deq;
            if (consumeReq.consumeInfo matches tagged ReadRespInfo .r) begin
                pendingConReqQ.enq(consumeReq);
            end
            busyReg <= False;
        end

        sendDmaWriteReq(consumeReq, payload);
    endrule

    rule genResp if (cntrl.isRTRorRTS);
        let dmaWriteResp <- dmaWriteSrv.response.get;
        let consumeReq = pendingConReqQ.first;
        pendingConReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged ReadRespInfo .readRespInfo: begin
                let consumeResp = PayloadConResp {
                    initiator   : consumeReq.initiator,
                    dmaWriteResp: DmaWriteResp {
                        sqpn    : readRespInfo.sqpn,
                        psn     : readRespInfo.psn
                    }
                };
                consumeRespQ.enq(consumeResp);
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let consumeResp = PayloadConResp {
                    initiator   : consumeReq.initiator,
                    dmaWriteResp: DmaWriteResp {
                        sqpn    : atomicRespDmaWriteMetaData.sqpn,
                        psn     : atomicRespDmaWriteMetaData.psn
                    }
                };
                consumeRespQ.enq(consumeResp);
            end
            default: begin end
        endcase
    endrule

    rule flushPayload if (cntrl.isERR);
        // When error, continue send DMA write requests,
        // so as to flush payload data properly laster.
        // But discard DMA write responses when error.
        if (!consumeReqQ.notEmpty && payloadPipeIn.notEmpty) begin
            payloadPipeIn.deq;
        end

        consumeRespQ.clear;
    endrule

    interface respPipeOut = convertFifo2PipeOut(consumeRespQ);
endmodule

/*
module mkDmaReadSrv(DmaReadSrv);
    FIFOF#(DmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;

    rule dmaSim;
        let req = dmaReadReqQ.first;
        dmaReadReqQ.deq;
        let resp = DmaReadResp {
            initiator: req.initiator,
            sqpn: req.sqpn,
            token: req.token
        };
        dmaReadRespQ.enq(resp);
    endrule

    interface Put#(DmaReadReq) request = toPut(dmaReadReqQ);
    interface Get#(DmaReadResp) response = toGet(dmaReadRespQ);
endmodule

// TODO: DMA write requests should read payload buffer
module mkDmaWriteSrv(DmaWriteSrv);
    FIFOF#(DmaWriteReq) dmaWriteReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ <- mkFIFOF;

    rule dmaSim;
        let req = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;
        if (req.token matches tagged Valid .token) begin
            let resp = DmaWriteResp {
                initiator: req.initiator,
                sqpn: req.sqpn,
                token: token
            };
            dmaWriteRespQ.enq(resp);
        end
    endrule

    interface Put#(DmaWriteReq) request = toPut(dmaWriteReqQ);
    interface Get#(DmaWriteResp) response = toGet(dmaWriteRespQ);
endmodule
*/