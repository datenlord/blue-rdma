import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;

import DataTypes :: *;

// interface Server#(type req_type, type resp_type);
//     interface Put#(req_type) request;
//     interface Get#(resp_type) response;
// endinterface: Server

typedef Server#(DmaReadReq, DmaReadResp) DmaReadSrv;
typedef Server#(DmaWriteReq, DmaWriteResp) DmaWriteSrv;

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
