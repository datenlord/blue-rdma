import BuildVector :: *;
import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import PrimUtils :: *;
import Utils :: *;
/*
function Tuple3#(Bool, Bit#(TLog#(portSz)), Vector#(portSz, Bool)) arbitrate(
    Vector#(portSz, Bool) priorityVec, Vector#(portSz, Bool) requestVec
);
    function Bool isTrue(Bool inputVal) = inputVal;

    let portNum = valueOf(portSz);

    Vector#(portSz, Bool) grantVec = replicate(False);
    Bit#(TLog#(portSz))   grantIdx = 0;

    Bool found   = True;
    Bool granted = False;
    for (Integer x = 0; x < (2 * portNum); x = x + 1) begin
        Integer y = (x % portNum);

        let hasReq = requestVec[y];
        let hasPriority = priorityVec[y];

        if (hasPriority) begin
            found = False;
        end

        if (!found && hasReq) begin
            grantVec[y] = True;
            grantIdx    = fromInteger(y);
            found   = True;
            granted = True;
        end
    end

    let nextPriorityVec = granted ? rotateR(grantVec) : priorityVec;
    return tuple3(granted, grantIdx, nextPriorityVec);
endfunction
*/
module mkServerArbiter#(
    Server#(reqType, respType) srv,
    function Bool isReqFinished(reqType request),
    function Bool isRespFinished(respType response)
)(Vector#(portSz, Server#(reqType, respType))) provisos(
    // FShow#(reqType), FShow#(respType),
    Bits#(reqType, reqSz),
    Bits#(respType, respSz),
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
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
        map(convertFifo2PipeOut, inputReqWithIdxVec),
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

function Bit#(TWO) arbitrateBinaryBits(
    Bit#(TWO) priorityBits, Bit#(TWO) requestBits
);
    let curGrant = priorityBits & requestBits;
    if (isZero(curGrant)) begin
        curGrant = requestBits;
    end
    return curGrant;
endfunction

module mkBinaryPipeOutArbiter#(
    PipeOut#(anytype) pipeIn1,
    PipeOut#(anytype) pipeIn2,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(Bits#(anytype, tSz));
    Vector#(TWO, PipeOut#(anytype)) inputPipeOutVec = vec(pipeIn2, pipeIn1);
    FIFOF#(anytype) pipeOutQ <- mkFIFOF;
    Reg#(Bool) needArbitrationReg <- mkReg(True);
    // Initial grant to LSB
    Reg#(Bit#(TWO)) priorityOneHotReg <- mkReg(1);
    Reg#(Bit#(TWO)) curGrantOneHotReg <- mkReg(1);

    function Bool portHasReqFunc(PipeOut#(anytype) pipeIn) = pipeIn.notEmpty;

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule binaryArbitrate;
        let requestVec = map(portHasReqFunc, inputPipeOutVec);
        Bit#(TWO) requestBits = pack(requestVec);

        // let newGrantOneHot = arbitrateByDoubleBits(priorityOneHotReg, requestBits);
        let newGrantOneHot = arbitrateBinaryBits(priorityOneHotReg, requestBits);

        let curGrantIdx = msb(curGrantOneHotReg);
        if (needArbitrationReg) begin
            curGrantIdx = msb(newGrantOneHot);
            curGrantOneHotReg <= newGrantOneHot;
            priorityOneHotReg <= ~newGrantOneHot;
        end

        immAssert(
            countOnes(priorityOneHotReg) == 1,
            "priorityOneHotReg assertion @ mkBinaryPipeOutArbiter",
            $format("priorityOneHotReg=%h", priorityOneHotReg, " should be onehot")
        );
        immAssert(
            countOnes(curGrantOneHotReg) == 1,
            "curGrantOneHotReg assertion @ mkBinaryPipeOutArbiter",
            $format("curGrantOneHotReg=%h", curGrantOneHotReg, " should be onehot")
        );

        let inputPayload = inputPipeOutVec[curGrantIdx].first;
        inputPipeOutVec[curGrantIdx].deq;
        pipeOutQ.enq(inputPayload);

        needArbitrationReg <= isPipePayloadFinished(inputPayload);

        // $display(
        //     "time=%0t:", $time,
        //     " needArbitrationReg=", fshow(needArbitrationReg),
        //     ", requestBits=%h, curGrantOneHotReg=%h, newGrantOneHot=%h, curGrantIdx=%h, priorityOneHotReg=%h",
        //     requestBits, curGrantOneHotReg, newGrantOneHot, curGrantIdx, priorityOneHotReg
        // );
    endrule

    return convertFifo2PipeOut(pipeOutQ);
endmodule

module mkBinaryPipeOutArbiterTree#(
    Vector#(portSz, PipeOut#(anytype)) inputPipeOutVec,
    function Bool isPipePayloadFinished(anytype pipePayload)
)(PipeOut#(anytype)) provisos(
    // FShow#(anytype),
    Bits#(anytype, tSz),
    // Add#(1, anysize, portSz),
    // Add#(1, anysizeK, TDiv#(portSz, 2))
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
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
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
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
    // FShow#(anytype),
    Bits#(anytype, tSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    let leafArbiterVec <- mkLeafBinaryPipeOutArbiterVec(
        inputPipeOutVec, isPipePayloadFinished
    );
    let resultPipeOut <- mkBinaryPipeOutArbiterTree(
        leafArbiterVec, isPipePayloadFinished
    );
    return resultPipeOut;
endmodule

// pipeIn1 has priority over pipeIn2
module mkFixedBinaryPipeOutArbiter#(
    PipeOut#(anytype) pipeIn1, PipeOut#(anytype) pipeIn2
)(PipeOut#(anytype));
    let isNotEmpty = pipeIn1.notEmpty || pipeIn2.notEmpty;

    method anytype first() if (isNotEmpty);
        if (pipeIn1.notEmpty) begin
            return pipeIn1.first;
        end
        else begin
            return pipeIn2.first;
        end
    endmethod

    method Action deq() if (isNotEmpty);
        if (pipeIn1.notEmpty) begin
            pipeIn1.deq;
        end
        else begin
            pipeIn2.deq;
        end
    endmethod

    method Bool notEmpty() = isNotEmpty;
endmodule

// // pipeIn1 has priority over pipeIn2
// function PipeOut#(anytype) mkFixedBinaryPipeOutArbiter(
//     PipeOut#(anytype) pipeIn1, PipeOut#(anytype) pipeIn2
// );
//     let notEmpty = pipeIn1.notEmpty || pipeIn2.notEmpty;
//     let resultIfc = interface PipeOut#(anytype);
//         method anytype first() if (notEmpty);
//             if (pipeIn1.notEmpty) begin
//                 return pipeIn1.first;
//             end
//             else begin
//                 return pipeIn2.first;
//             end
//         endmethod

//         method Action deq() if (notEmpty);
//             if (pipeIn1.notEmpty) begin
//                 pipeIn1.deq;
//             end
//             else begin
//                 pipeIn2.deq;
//             end
//         endmethod

//         method Bool notEmpty() = notEmpty;
//     endinterface;

//     return resultIfc;
// endfunction
