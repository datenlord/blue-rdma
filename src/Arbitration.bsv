import BuildVector :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import PrimUtils :: *;
import RdmaUtils :: *;

import Arbiter :: * ;

module mkTwoWayFixedPriorityStreamMux#(
    String name,
    Bool enableDebug,
    Vector#(2, PipeOut#(reqType)) inVec,
    function Bool isReqFinished(reqType request)
)(Get#(Tuple2#(Bool, reqType))) provisos(
    FShow#(reqType), 
    Bits#(reqType, reqSz)
);

    Reg#(Bool) isIdleReg <- mkReg(True);
    Reg#(Bool) isForwardingCh0Reg <- mkReg(False);

    FIFOF#(Tuple2#(Bool, reqType))   reqQ <- mkFIFOF;

    rule handleIdle if (isIdleReg);
        let hasReq = inVec[0].notEmpty || inVec[1].notEmpty;
        let data = ?;
        let isForwardingCh0 = ?;
        if (inVec[0].notEmpty) begin
            data = inVec[0].first;
            inVec[0].deq;
            isForwardingCh0 = True;
        end
        else if (inVec[1].notEmpty) begin
            data = inVec[1].first;
            inVec[1].deq;
            isForwardingCh0 = False;
        end
        isForwardingCh0Reg <= isForwardingCh0;

        if (hasReq) begin
            reqQ.enq(tuple2(isForwardingCh0, data));
            if (!isReqFinished(data)) begin
                isIdleReg <= False;
            end
        end
    endrule

    rule handleForward if (!isIdleReg);
        let data = ?;
        if (isForwardingCh0Reg) begin
            data = inVec[0].first;
            inVec[0].deq;
        end
        else begin
            data = inVec[1].first;
            inVec[1].deq;
        end
        reqQ.enq(tuple2(isForwardingCh0Reg, data));
        if (isReqFinished(data)) begin
            isIdleReg <= True;
        end
    endrule

    return toGet(reqQ);
endmodule


module mkClientArbiter#(
    String name,
    Bool enableDebug,
    Integer keepOrderQueueLen,
    Vector#(portSz, Client#(reqType, respType)) clientVec,
    function Bool isReqFinished(reqType request),
    function Bool isRespFinished(respType response)
)(Client#(reqType, respType)) provisos(
    // FShow#(reqType), FShow#(respType),
    Bits#(reqType, reqSz),
    Bits#(respType, respSz),
    Add#(1, anysize, portSz)
);

    Arbiter_IFC#(portSz)                arbiter                 <- mkArbiter(False);
    Reg#(Bool)                          canSubmitArbitReqReg    <- mkReg(True);
    Vector#(portSz, FIFOF#(reqType))    clientReqFifoVec        <- replicateM(mkFIFOF);
    // Vector#(portSz, FIFOF#(respType)) clientRespFifoVec <- replicateM(mkFIFOF);

    // A trick here. This fifo's size must be small, and it should be smaller than portSz, or it will
    // queue too many granted requests ahead of time (mkArbiter will do arbit every clock cycle)
    FIFOF#(Bit#(TLog#(portSz))) grantReqKeepOrderQ <- mkFIFOF;
    // This Fifo can be larger since receive response may take some time and there can be many outstanding requests.
    FIFOF#(Bit#(TLog#(portSz))) grantRespKeepOrderQ <- mkSizedFIFOF(keepOrderQueueLen);

    FIFOF#(reqType)   reqQ <- mkFIFOF;
    FIFOF#(respType) respQ <- mkFIFOF;

    // convert input Get interface to a FIFOF since we need full/empty signal
    // THIS QUEUE MUST BE SIZE OF 2, SO WHEN IT FULL IT MEANS THAT WE HAVE TO ELEMENTS IN QUEUE NOW.
    for (Integer idx=0; idx < valueOf(portSz); idx=idx+1) begin
        mkConnection(clientVec[idx].request, toPut(clientReqFifoVec[idx]));
    end

    rule forwardRequest if (!canSubmitArbitReqReg);
        let idx = grantReqKeepOrderQ.first;
        let req = clientReqFifoVec[idx].first;
        clientReqFifoVec[idx].deq;
        reqQ.enq(req);

        let reqFinished = isReqFinished(req);
        if (reqFinished) begin
            canSubmitArbitReqReg <= True;
            grantReqKeepOrderQ.deq;
        end
        
        if (enableDebug) begin
            $display(
                "time=%0t: ", $time,
                fshow(name),
                " arbitrate request, reqIdx=%0d", idx,
                ", reqFinished=", fshow(reqFinished)
            );
        end
    endrule

    for (Integer idx=0; idx < valueOf(portSz); idx=idx+1) begin
        rule sendArbitReq;
            if (enableDebug) begin
                $display(
                    "time=%0t: ", $time,
                    fshow(name),
                    " arbitrate sendArbitReq debug, reqIdx=%0d", idx,
                    " canSubmitArbitReqReg = ", fshow(canSubmitArbitReqReg),
                    " clientReqFifoVec[idx].notEmpty = ", fshow(clientReqFifoVec[idx].notEmpty)
                );
            end
            
            if (canSubmitArbitReqReg) begin
                arbiter.clients[idx].request;
                if (enableDebug) begin
                    $display(
                        "time=%0t: ", $time,
                        fshow(name),
                        " arbitrate submit req, reqIdx=%0d", idx
                    );
                end
            end
        endrule

        

        rule forwardResponse if (grantRespKeepOrderQ.first == fromInteger(idx));
            let resp = respQ.first;
            respQ.deq;
            clientVec[idx].response.put(resp);
            let respFinished = isRespFinished(resp);
            if (respFinished) begin
                grantRespKeepOrderQ.deq;
            end

            if (enableDebug) begin
                $display(
                    "time=%0t: ", $time,
                    fshow(name),
                    " dispatch response, idx=%0d", idx,
                    ", respFinished=", fshow(respFinished)
                );
            end
        endrule
    end

    rule recvArbitResp if (canSubmitArbitReqReg);

        Vector#(portSz, Bool) arbiterRespVec;
        for (Integer idx=0; idx < valueOf(portSz); idx=idx+1) begin
            arbiterRespVec[idx] = arbiter.clients[idx].grant;
        end
        if (enableDebug) begin
            $display(
                "time=%0t: ", $time,
                fshow(name),
                " arbit result=", fshow(arbiterRespVec)
            );
        end
        if (pack(arbiterRespVec) != 0) begin
            let idx = arbiter.grant_id;
            let req = clientReqFifoVec[idx].first;

            reqQ.enq(req);
            clientReqFifoVec[idx].deq;
            grantRespKeepOrderQ.enq(idx);

            if (!isReqFinished(req)) begin
                grantReqKeepOrderQ.enq(idx);
                canSubmitArbitReqReg <= False;
                if (enableDebug) begin
                    $display(
                        "time=%0t: ", $time,
                        fshow(name),
                        " grant new single beat request, client idx=%0d", idx
                    );
                end
            end
            
            if (enableDebug) begin
                $display(
                    "time=%0t: ", $time,
                    fshow(name),
                    " grant new request, client idx=%0d", idx
                );
            end
        end

    endrule

    rule debug if (enableDebug);
        if (!reqQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " reqQ");
        end
        if (!respQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " respQ");
        end

        if (!reqQ.notEmpty) begin
            $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " reqQ");
        end
        if (!respQ.notEmpty) begin
            $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " respQ");
        end

        if (!grantReqKeepOrderQ.notEmpty) begin
            $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " grantReqKeepOrderQ");
        end

        if (!grantReqKeepOrderQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " grantReqKeepOrderQ");
        end

        if (!grantRespKeepOrderQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " grantRespKeepOrderQ");
        end

        for (Integer idx=0; idx < valueOf(portSz); idx=idx+1) begin

            if (!clientReqFifoVec[idx].notFull) begin
                $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " clientReqFifoVec[%0d]", idx);
            end

            if (!clientReqFifoVec[idx].notEmpty) begin
                $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkClientArbiter ", fshow(name) , " clientReqFifoVec[%0d]", idx);
            end
            
        end
    endrule


    return toGPClient(reqQ, respQ);
endmodule


module mkServerArbiter#(
    Server#(reqType, respType) srv,
    function Bool isReqFinished(reqType request),
    function Bool isRespFinished(respType response)
)(Vector#(portSz, Server#(reqType, respType))) provisos(
    // FShow#(reqType), FShow#(respType),
    Bits#(reqType, reqSz),
    Bits#(respType, respSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
);
    function Bool isPipePayloadFinished(Tuple2#(Bit#(TLog#(portSz)), reqType) reqWithIdx);
        let { reqIdx, inputReq } = reqWithIdx;
        return isReqFinished(inputReq);
    endfunction

    Vector#(portSz, Server#(reqType, respType)) resultSrvVec = newVector;

    Vector#(
        portSz, FIFOF#(Tuple2#(Bit#(TLog#(portSz)), reqType))
    ) inputReqWithIdxVec <- replicateM(mkFIFOF);
    Vector#(portSz, FIFOF#(respType)) respVec <- replicateM(mkFIFOF);
    FIFOF#(Bit#(TLog#(portSz)))  preGrantIdxQ <- mkFIFOF;
    Reg#(Bool) shouldSaveGrantIdxReg <- mkReg(True);

    let leafArbiterVec <- mkLeafBinaryPipeOutArbiterVec(
        map(toPipeOut, inputReqWithIdxVec),
        isPipePayloadFinished
    );
    let finalReqWithIdxPipeOut <- mkBinaryPipeOutArbiterTree(
        leafArbiterVec, isPipePayloadFinished
    );

    rule issueArbitratedReq;
        let { reqIdx, inputReq } = finalReqWithIdxPipeOut.first;
        finalReqWithIdxPipeOut.deq;
        srv.request.put(inputReq);

        if (shouldSaveGrantIdxReg) begin
            preGrantIdxQ.enq(reqIdx);
        end
        shouldSaveGrantIdxReg <= isReqFinished(inputReq);
    endrule

    for (Integer idx = 0; idx < valueOf(portSz); idx = idx + 1) begin
        resultSrvVec[idx] = interface Server#(reqType, respType);
            interface request = interface Put#(reqType);
                method Action put(reqType inputReq);
                    inputReqWithIdxVec[idx].enq(tuple2(
                        fromInteger(idx), inputReq
                    ));
                endmethod
            endinterface;

            interface response = toGet(respVec[idx]);
        endinterface;
    end

    rule dispatchResponse;
        let preGrantIdx = preGrantIdxQ.first;
        let resp <- srv.response.get;

        let respFinished = isRespFinished(resp);
        respVec[preGrantIdx].enq(resp);
        if (respFinished) begin
            preGrantIdxQ.deq;
        end

        // $display(
        //     "time=%0t:", $time,
        //     " dispatch resp=", fshow(resp),
        //     ", preGrantIdx=%0d", preGrantIdx,
        //     ", respFinished=", fshow(respFinished)
        // );
    endrule

    return resultSrvVec;
endmodule

function Bit#(nSz) arbitrateBits(
    Bit#(nSz) priorityBits, Bit#(nSz) requestBits
); // provisos(Add#(1, anysize, nSz));
    let maskBits = priorityBits - 1;
    let maskedReqBits = requestBits & ~maskBits;
    let maskedGrantOneHot = maskedReqBits & ~(maskedReqBits - 1);
    let noMaskedGrantOneHot = requestBits & ~(requestBits - 1);
    return isZero(maskedReqBits) ? noMaskedGrantOneHot : maskedGrantOneHot;
endfunction

function Bit#(nSz) arbitrateByDoubleBits(
    Bit#(nSz) priorityBits, Bit#(nSz) requestBits
) provisos(
    Add#(1, anysizeJ, nSz),
    Add#(nSz, anysizeK, doubleSz),
    NumAlias#(TMul#(nSz, 2), doubleSz)
);
    Bit#(doubleSz) doubleMask = zeroExtend(priorityBits - 1);
    let doubleReq = { requestBits, requestBits };
    let maskedDoubleReq = doubleReq & ~doubleMask;
    let doubleGrantOneHot = maskedDoubleReq & ~(maskedDoubleReq - 1);
    Bit#(nSz) highPart = truncateLSB(doubleGrantOneHot);
    Bit#(nSz) lowPart = truncate(doubleGrantOneHot);
    let grantOneHot = highPart | lowPart;
    return grantOneHot;
endfunction

module mkBinaryPipeOutArbiter#(
    PipeOut#(anytype) pipeIn1,
    PipeOut#(anytype) pipeIn2,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(Bits#(anytype, tSz));
    Vector#(TWO, PipeOut#(anytype)) inputPipeOutVec = vec(pipeIn1, pipeIn2);
    FIFOF#(anytype) pipeOutQ <- mkFIFOF;
    Reg#(Bool) needArbitrationReg <- mkReg(True);
    // Initial grant to LSB
    Reg#(Bool) priorityReg <- mkReg(False);
    Reg#(Bool)    grantReg <- mkReg(False);

    let shouldGrantPipeIn2 = (priorityReg && pipeIn2.notEmpty) || (!pipeIn1.notEmpty && pipeIn2.notEmpty);

    (* fire_when_enabled *)
    rule binaryArbitrate;
        Bit#(TLog#(TWO)) curGrantIdx = pack(grantReg);

        if (needArbitrationReg) begin
            curGrantIdx = pack(shouldGrantPipeIn2);
            grantReg    <= shouldGrantPipeIn2;
            priorityReg <= !shouldGrantPipeIn2;
        end

        let inputPayload = inputPipeOutVec[curGrantIdx].first;
        inputPipeOutVec[curGrantIdx].deq;
        pipeOutQ.enq(inputPayload);

        needArbitrationReg <= isPipePayloadFinished(inputPayload);

        // $display(
        //     "time=%0t:", $time,
        //     " needArbitrationReg=", fshow(needArbitrationReg),
        //     ", curGrantIdx=%0d, grantReg=%h, priorityReg=%h",
        //     curGrantIdx, grantReg, priorityReg,
        //     ", shouldGrantPipeIn2=", fshow(shouldGrantPipeIn2)
        // );
    endrule

    return toPipeOut(pipeOutQ);
endmodule

module mkBinaryPipeOutArbiterTree#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(
    // FShow#(anytype),
    Bits#(anytype, tSz),
    // Add#(1, anysize, portSz),
    // Add#(1, anysizeK, TDiv#(portSz, 2))
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
);

    if (valueOf(portSz) == 1) begin
        return inputPipeOutVec[0];
    end
    else begin
        Vector#(TDiv#(portSz, TWO), PipeOut#(anytype)) arbiterVec = newVector;

        for (Integer idx = 0; idx < valueOf(portSz); idx = idx + valueOf(TWO)) begin
            let arbiterIdx = idx / valueOf(TWO);
            let binaryArbiter <- mkBinaryPipeOutArbiter(
                inputPipeOutVec[idx], inputPipeOutVec[idx + 1], isPipePayloadFinished
            );
            arbiterVec[arbiterIdx] = binaryArbiter;
        end

        let resultPipeOut <- mkBinaryPipeOutArbiterTree(arbiterVec, isPipePayloadFinished);
        return resultPipeOut;
    end
endmodule

module mkLeafBinaryPipeOutArbiterVec#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(
    Vector#(TDiv#(portSz, TWO), PipeOut#(anytype))
) provisos(
    // FShow#(anytype),
    Bits#(anytype, tSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
);
    Vector#(TDiv#(portSz, TWO), PipeOut#(anytype)) leafArbiterVec = newVector;

    // FFT style bit-reverse
    for (Integer idx = 0; idx < valueOf(portSz); idx = idx + valueOf(TWO)) begin
        let arbiterIdx = idx / valueOf(TWO);
        Bit#(TLog#(portSz)) left  = fromInteger(idx);
        Bit#(TLog#(portSz)) right = fromInteger(idx + 1);
        let leftIdx  = reverseBits(left);
        let rightIdx = reverseBits(right);
        let binaryArbiter <- mkBinaryPipeOutArbiter(
            inputPipeOutVec[leftIdx], inputPipeOutVec[rightIdx], isPipePayloadFinished
        );
        leafArbiterVec[arbiterIdx] = binaryArbiter;
    end

    return leafArbiterVec;
endmodule

module mkPipeOutArbiter#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(
    FShow#(anytype),
    Bits#(anytype, tSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
);
    let leafArbiterVec <- mkLeafBinaryPipeOutArbiterVec(
        inputPipeOutVec, isPipePayloadFinished
    );
    let resultPipeOut <- mkBinaryPipeOutArbiterTree(
        leafArbiterVec, isPipePayloadFinished
    );

    return resultPipeOut;
endmodule

interface ServerProxy#(type reqType, type respType);
    interface Server#(reqType, respType) srvPort;
    interface Client#(reqType, respType) cltPort;
endinterface

module mkServerProxy(ServerProxy#(reqType, respType)) provisos(
    Bits#(reqType, reqSz), Bits#(respType, respSz)
);
    FIFOF#(reqType)   reqQ <- mkFIFOF;
    FIFOF#(respType) respQ <- mkFIFOF;

    interface cltPort = toGPClient(reqQ, respQ);
    interface srvPort = toGPServer(reqQ, respQ);
endmodule
