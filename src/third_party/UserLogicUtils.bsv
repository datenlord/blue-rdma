import ClientServer :: * ;
import GetPut :: *;
import Connectable :: *;
import PAClib :: *;
import Gearbox :: *;
import Vector :: *;
import Ports :: *;
import FIFOF :: *;

import PrimUtils :: *;
import DataTypes :: *;
import RdmaUtils :: *;



import UserLogicSettings :: *;
import UserLogicTypes :: *;


function RingbufRawDescriptorOpcode getCmdQueueOpcodeFromRawRingbufDescriptor(RingbufRawDescriptor desc);
    return pack(desc)[valueOf(CMD_QUEUE_RINGBUF_DESC_OPCODE_OFFSET) + valueOf(CMD_QUEUE_RINGBUF_DESC_OPCODE_LENGTH) - 1 :valueOf(CMD_QUEUE_RINGBUF_DESC_OPCODE_OFFSET)];
endfunction

module mkFakeClient(Client#(t_req, t_resp));
    Reg#(Bool) t <- mkReg(False);
    interface Get request;
        method ActionValue#(t_req) get() if (t);
            return ?;
        endmethod
    endinterface
    interface Put response;
        method Action put(t_resp val) if (t);
        endmethod
    endinterface
endmodule