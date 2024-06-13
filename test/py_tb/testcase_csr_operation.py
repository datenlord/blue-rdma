from mock_host import *
from test_case_common import *
from utils import print_mem_diff, assert_descriptor_bth_reth, assert_descriptor_bth_aeth

PMTU_VALUE_FOR_TEST = PMTU.IBV_MTU_256

RECV_SIDE_IP = NIC_CONFIG_IPADDR
RECE_SIDE_MAC = NIC_CONFIG_MACADDR
RECV_SIDE_QPN = SEND_SIDE_QPN + 1
SEND_SIDE_PSN_INIT_VAL = 0x0
SEND_SIDE_MSN_INIT_VAL = 0x2

PMTU_VAL = 256 * (2 ** (PMTU_VALUE_FOR_TEST-1))
PACKET_CNT = 32
SEND_BYTE_COUNT = PMTU_VAL * PACKET_CNT


def test_case(host_mem):
    send_psn = SEND_SIDE_PSN_INIT_VAL
    send_msn = SEND_SIDE_MSN_INIT_VAL
    mock_nic = EmulatorMockNicAndHost(host_mem)
    pkt_agent = NetworkDataAgent(mock_nic)
    mock_nic.run()

    # ================================
    # 1st case, Write Reset Reg
    #
    # Note, this should be the first test case, so we can use following testcase to
    # check the hardware still works after reset
    # ================================

    # first, modify an register
    mock_nic.write_csr_blocking(
        CSR_ADDR_CMD_REQ_QUEUE_ADDR_LOW, 4096)
    readback = mock_nic.read_csr_blocking(CSR_ADDR_CMD_REQ_QUEUE_ADDR_LOW)
    if readback != 4096:
        print("Error: Error at read back, expected=200, got ", readback)
        raise SystemExit

    # second, do soft reset
    mock_nic.write_csr_non_blocking(
        CSR_ADDR_HARDWARE_GLOBAL_CONTROL_SOFT_RESET, 1)

    time.sleep(1)

    # third, check reg reseted
    readback = mock_nic.read_csr_blocking(CSR_ADDR_CMD_REQ_QUEUE_ADDR_LOW)
    if readback != 0:
        print("Error: Error at read back, expected=0, got ", readback)
        raise SystemExit
    else:
        print("PASS-1")

    # ================================
    # 2nd case, read const CSR
    # ================================

    expected_hw_ver = 2024042901
    hw_ver = mock_nic.read_csr_blocking(CSR_ADDR_HARDWARE_CONST_HW_VERSION)
    if hw_ver != expected_hw_ver:
        print("Error: Error at read HW version CSR, expected=",
              expected_hw_ver, ", got ", hw_ver)
        raise SystemExit
    else:
        print("PASS-2")


if __name__ == "__main__":
    # must wrap test case in a function, so when the function returned, the memory view will be cleaned
    # otherwise, there will be an warning at program exit.
    run_test_case(test_case)
