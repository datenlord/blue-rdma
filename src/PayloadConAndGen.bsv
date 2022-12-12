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

    rule flushPayloadGenResp if (cntrl.isERR);
        // TODO: clean generateReqQ and generateRespQ
        let dmaReadResp <- dmaReadSrv.response.get;
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
    method Action request(PayloadConReq req);
    interface PipeOut#(PayloadConResp) respPipeOut;
endinterface

module mkPayloadConsumer#(
    Controller cntrl,
    DataStreamPipeOut payloadPipeIn,
    DmaWriteSrv dmaWriteSrv
)(PayloadConsumer);
    FIFOF#(PayloadConReq)   consumeReqQ <- mkFIFOF;
    FIFOF#(PayloadConResp) consumeRespQ <- mkFIFOF;

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    // Reg#(PayloadConReq)     curReqReg <- mkRegU;
    // Reg#(Bool) busyReg <- mkReg(False);

    function Action respPayloadConsume(PayloadConReq consumeReq, DataStream payload);
        action
            dynAssert(
                payload.isLast,
                "payload.isLast assertion @ mkPayloadConsumer",
                $format(
                    "payload.isLast=%b should be true when remainingFragNumReg=%0d",
                    payload.isLast, remainingFragNumReg
                )
            );

            if (consumeReq.dmaWriteMetaData matches tagged Valid .dmaWriteMetaData) begin
                let consumeResp = PayloadConResp {
                    initiator   : consumeReq.initiator,
                    dmaWriteResp: DmaWriteResp {
                        sqpn    : dmaWriteMetaData.sqpn,
                        psn     : dmaWriteMetaData.psn
                    }
                };
                consumeRespQ.enq(consumeResp);
            end
        endaction
    endfunction

    rule consumePayload if (cntrl.isRTRorRTS);
        let consumeReq = consumeReqQ.first;
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        remainingFragNumReg <= remainingFragNumReg - 1;
        if (isZero(remainingFragNumReg)) begin
            consumeReqQ.deq;
            // busyReg <= False;
            respPayloadConsume(consumeReq, payload);
        end
    endrule

    rule flushPayload if (cntrl.isERR);
        if (!consumeReqQ.notEmpty && payloadPipeIn.notEmpty) begin
            payloadPipeIn.deq;
        end
        if (consumeRespQ.notEmpty) begin
            consumeRespQ.deq;
        end
    endrule

    method Action request(PayloadConReq consumeReq) if (cntrl.isRTRorRTS);
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        dynAssert(
            !isZero(consumeReq.fragNum),
            "consumeReq.fragNum assertion @ mkPayloadConsumer",
            $format(
                "consumeReq.fragNum=%0d should not be zero",
                consumeReq.fragNum
            )
        );

        if (isLargerThanOne(consumeReq.fragNum)) begin
            remainingFragNumReg <= consumeReq.fragNum - 2;
            consumeReqQ.enq(consumeReq);
            // busyReg <= True;
        end
        else begin
            respPayloadConsume(consumeReq, payload);
        end
    endmethod

    interface respPipeOut = convertFifo2PipeOut(consumeRespQ);
    // interface request = toPut(consumeReqQ);
    // interface response = toGet(consumeRespQ);
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