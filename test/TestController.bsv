import Cntrs :: *;
import List :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils4Test :: *;

(* doc = "testcase" *)
module mkTestCntrlInVec(Empty);
    let qpType = IBV_QPT_XRC_RECV;
    let pmtu = IBV_MTU_1024;

    Vector#(MAX_QP, CntrlQP) cntrlVec <- replicateM(
        mkSimCntrl(qpType, pmtu)
    );
    // let setExpectedPsnAsNextPSN = False;
    // Vector#(MAX_QP, CntrlQP) cntrlVec <- replicateM(mkSimCntrlQP(
    //     qpType, pmtu, setExpectedPsnAsNextPSN
    // ));
    Array#(CntrlQP) cntrlArray = vectorToArray(cntrlVec);
    List#(CntrlQP) cntrlList = toList(cntrlVec);

    Count#(Bit#(TLog#(TAdd#(1, MAX_QP)))) qpCnt <- mkCount(0);
    Reg#(Bool) stateReg <- mkReg(True);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule setCntrl if (stateReg);
        let cntrl = cntrlArray[qpCnt];
        let cntrlStatus = cntrl.contextSQ.statusSQ;

        if (qpCnt == fromInteger(valueOf(MAX_QP))) begin
            stateReg <= False;
            qpCnt <= 0;
        end
        else if (cntrlStatus.comm.isStableRTS) begin
            cntrl.contextRQ.setCurRespPSN(cntrl.contextRQ.getEPSN);
            qpCnt.incr(1);

            // $display(
            //     "time=%0t: cntrlVec[%0d].contextRQ.getEPSN=%h",
            //     $time, qpCnt, cntrl.contextRQ.getEPSN
            // );
        end
    endrule

    rule cmpCntrl if (!stateReg);
        countDown.decr;

        if (qpCnt == fromInteger(valueOf(MAX_QP))) begin
            stateReg <= True;
            qpCnt <= 0;
        end
        else begin
            qpCnt.incr(1);

            let cntrl1 = cntrlVec[qpCnt];
            let cntrl2 = cntrlArray[qpCnt];

            immAssert(
                cntrl1.contextSQ.statusSQ.comm.getQKEY == cntrl2.contextSQ.statusSQ.comm.getQKEY,
                "qkey assertion @ mkTestCntrlInVec",
                $format(
                    "cntrl1.contextSQ.statusSQ.comm.getQKEY=%h == cntrl2.contextSQ.statusSQ.comm.getQKEY=%h",
                    cntrl1.contextSQ.statusSQ.comm.getQKEY, cntrl2.contextSQ.statusSQ.comm.getQKEY
                )
            );
            immAssert(
                cntrl1.contextRQ.getCurRespPSN == cntrl2.contextRQ.getEPSN,
                "curRespPsn assertion @ mkTestCntrlInVec",
                $format(
                    "curRespPsn=%h == cntrl2.contextRQ.getEPSN=%h",
                    cntrl1.contextRQ.getCurRespPSN, cntrl2.contextRQ.getEPSN
                )
            );
            // $display(
            //     "time=%0t: cntrl1.cntrlStatus.comm.getQKEY=%h == cntrl2.cntrlStatus.comm.getQKEY=%h",
            //     $time, cntrl1.cntrlStatus.comm.getQKEY, cntrl2.cntrlStatus.comm.getQKEY
            // );
        end
    endrule
endmodule
