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

typedef Server#(PayloadConsumeReq, PayloadConsumeResp) PayloadConsumer;

function DataStream getDataStreamFromPayloadGenRespPipeOut(
    PayloadGenResp resp
) = resp.dmaReadResp.data;

interface PayloadGenerator;
    method Action request(PayloadGenReq req);
    interface PipeOut#(PayloadGenResp) respPipeOut;
endinterface

module mkPayloadGenerator#(
    Controller cntlr,
    DmaReadSrv dmaReadSrv
)(PayloadGenerator);
    // FIFOF#(PayloadGenReq)   generateReqQ <- mkFIFOF;
    FIFOF#(PayloadGenResp) generateRespQ <- mkFIFOF;
    FIFOF#(Tuple2#(Bool, ByteEn)) paddingQ <- mkFIFOF;
    // Reg#(Bool)                  addPaddingReg <- mkRegU;
    // Reg#(ByteEn) lastFragByteEnWithPaddingReg <- mkRegU;

    // Reg#(Bool) busyReg <- mkReg(False);

    rule generatePayload if (cntlr.isRTRorRTS);
        let dmaReadResp <- dmaReadSrv.response.get;
        let { addPaddingReg, lastFragByteEnWithPadding } = paddingQ.first;

        if (dmaReadResp.data.isLast) begin
            paddingQ.deq;

            if (addPaddingReg) begin
                dmaReadResp.data.byteEn = lastFragByteEnWithPadding;
            end
        end

        let generateResp = PayloadGenResp {
            dmaReadResp: dmaReadResp,
            addPadding: addPaddingReg
        };
        generateRespQ.enq(generateResp);
    endrule

    rule flushResp if (cntlr.isErr);
        let dmaReadResp <- dmaReadSrv.response.get;
    endrule

    method Action request(PayloadGenReq generateReq) if (cntlr.isRTRorRTS);
        // let generateReq = generateReqQ.first;
        // generateReqQ.deq;
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
                "lastFragValidByteNumWithPadding=%0d should not be zero, dmaLen=%0d, lastFragValidByteNum=%0d, padCnt=%0d",
                lastFragValidByteNumWithPadding, dmaLen, lastFragValidByteNum, padCnt
            )
        );
        // addPaddingReg <= generateReq.addPadding;
        // if (generateReq.addPadding) begin
        //     lastFragByteEnWithPaddingReg <= lastFragByteEnWithPadding
        // end
        paddingQ.enq(tuple2(generateReq.addPadding, lastFragByteEnWithPadding));
        dmaReadSrv.request.put(generateReq.dmaReadReq);
        // busyReg <= True;
    endmethod

    interface respPipeOut = convertFifo2PipeOut(generateRespQ);
    // interface request = toPut(consumeReqQ);
    // interface response = toGet(consumeRespQ);
endmodule

// Cannel payload DMA write request when in error state
module mkPayloadConsumer#(
    Controller cntlr,
    DataStreamPipeOut payloadPipeIn,
    DmaWriteSrv dmaWriteSrv
)(PayloadConsumer);
    FIFOF#(PayloadConsumeReq) consumeReqQ <- mkFIFOF;
    FIFOF#(PayloadConsumeResp) consumeRespQ <- mkFIFOF;

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);

    function Action respPayloadConsume(PayloadConsumeReq consumeReq, DataStream payload);
        action
            dynAssert(
                payload.isLast,
                "payload.isLast assertion @ mkPayloadConsumer",
                $format(
                    "payload.isLast=%b should be true when remainingFragNumReg=%0d",
                    payload.isLast, remainingFragNumReg
                )
            );

            consumeReqQ.deq;
            if (consumeReq.dmaWriteReq matches tagged Valid .dmaWriteReq) begin
                let consumeResp = PayloadConsumeResp {
                    dmaWriteResp: DmaWriteResp {
                        initiator: dmaWriteReq.initiator,
                        sqpn     : dmaWriteReq.sqpn,
                        psn      : dmaWriteReq.psn
                    }
                };
                consumeRespQ.enq(consumeResp);
            end
        endaction
    endfunction

    rule recvReq if (cntlr.isRTRorRTS && !busyReg);
        let consumeReq = consumeReqQ.first;
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
            busyReg <= True;
        end
        else begin
            respPayloadConsume(consumeReq, payload);
        end
    endrule

    rule consumePayload if (cntlr.isRTRorRTS && busyReg);
        let consumeReq = consumeReqQ.first;
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        remainingFragNumReg <= remainingFragNumReg - 1;
        if (isZero(remainingFragNumReg)) begin
            busyReg <= False;
            respPayloadConsume(consumeReq, payload);
        end
    endrule

    rule flushPayload if (cntlr.isErr);
        payloadPipeIn.deq;
    endrule

    interface request = toPut(consumeReqQ);
    interface response = toGet(consumeRespQ);
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