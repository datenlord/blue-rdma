#!/usr/bin/tclsh

# puts $rdi::task_libraries
# puts $rdi::ldext

proc find_cmd {option} {
  foreach cmd [lsort [info commands *]] {
    catch {
      if {[regexp "$option" [help -syntax $cmd]]} {
        puts $cmd
      }
    }
  }
}
# To find the Vivado tools commands that support the -return_string option use:
# findCmd return_string

####################################################################################################
# STEP#1: define the output directory area
####################################################################################################
set out_dir $::env(OUTPUT)
# file delete -force -- $out_dir
file mkdir $out_dir

set top_module $::env(TOP)
set rtl_dir $::env(RTL)
set xdc_dir $::env(XDC)
set ips_dir $::env(IPS)
set ooc_synth $::env(OOCSYNTH)
set run_to $::env(RUNTO)
set target_clks $::env(CLOCKS)
set part $::env(PART)

set_param general.maxthreads 24
set device [get_parts $part]; # xcvu13p-fhgb2104-2-i; #
set_part $device

set MAX_NET_PATH_NUM 1000
# set MAX_LOGIC_LEVEL 40
# set MIN_LOGIC_LEVEL 4

set SYNTH_MODE default
if {$ooc_synth} {
    set SYNTH_MODE out_of_context
    # config_timing_analysis -ignore_io_paths true
}

set SYNTH_PHASE synth
set PLACE_PHASE place
set ROUTE_PHASE route
set ALL_PHASE all

set EN_PHYS_OPT 0
set NUM_PHYS_OPT_ITERS 1
set RQA_DIR rqa
set RQS_DIR rqs

proc should_start_gui {run_to_phase cur_phase} {
    set str1 [string trim $run_to_phase]
    set str2 [string trim $cur_phase]
    set str_cmp_result [string compare $str1 $str2]
    if {$str_cmp_result == 0} {
        puts "finish $run_to_phase phase and start GUI"
        start_gui
        puts "return from GUI and continue to run"
    } else {
        puts "finish $cur_phase phase, continue running until $run_to_phase phase"
    }
}

proc should_run_phys_opt {} {
    set worst_slack [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    if {$worst_slack >= -0.3 && $worst_slack < 0} {
        puts "WNS=$worst_slack, running physical optimization"
        return 1
    } else {
        puts "WNS=$worst_slack, not to run physical optimization"
        return 0
    }
}

####################################################################################################
# STEP#2: setup design sources, ips and constraints
####################################################################################################
read_verilog [glob $rtl_dir/*.v]
read_xdc [glob $xdc_dir/*.xdc] -mode $SYNTH_MODE
if {[file exists $ips_dir] && [file isdirectory $ips_dir]} {
    foreach ip_script [glob $ips_dir/*.tcl] {
        source $ip_script
    }
}
# read_ip [glob $ip_dir/*/*.xci]

####################################################################################################
# STEP#3: generate ip, run synthesis, write design checkpoint, report timing,
# and utilization estimates
####################################################################################################
report_property $device -file $out_dir/pre_synth_dev_prop.rpt
report_param -file $out_dir/pre_synth_param.rpt
foreach ip [get_ips *] {
    set gen_dcp [get_property GENERATE_SYNTH_CHECKPOINT [get_files ${ip}.xci]]
    if {$gen_dcp} {
        synth_ip $ip
    } else {
        generate_target all $ip
    }
}
# set all_ips [get_ips *]
# generate_target all $all_ips
# synth_ip $all_ips; # -quiet
set_property TOP $top_module [current_fileset]
synth_design -top $top_module -mode $SYNTH_MODE; # -directive AlternateRoutability -retiming -control_set_opt_threshold 16
opt_design; # -hier_fanout_limit 512 -directive ExploreWithRemap -remap -control_set_merge -merge_equivalent_drivers
power_opt_design

if {$ooc_synth} {
    config_timing_analysis -ignore_io_paths true
}
write_checkpoint -force $out_dir/post_synth.dcp
# Generated XDC file should be less than 1MB, otherwise too many constraints.
write_xdc -force -exclude_physical $out_dir/post_synth.xdc
write_xdc -force -constraints INVALID $out_dir/post_synth_invalid.xdc

report_compile_order -file $out_dir/post_synth_compile_order.rpt; # -constraints
# Check 1) slack, 2) requirement, 3) src and dst clocks, 4) datapath delay, 5) logic level, 6) skew and uncertainty.
report_timing_summary -report_unconstrained -warn_on_violation -file $out_dir/post_synth_timing_summary.rpt
report_timing -of_objects [get_timing_paths -setup -to [get_clocks $target_clks] -max_paths $MAX_NET_PATH_NUM -filter { LOGIC_LEVELS >= 4 && LOGIC_LEVELS <= 40 }] -file $out_dir/post_synth_long_paths.rpt
# Check 1) endpoints without clock, 2) combo loop and 3) latch.
check_timing -override_defaults no_clock -file $out_dir/post_synth_check_timing.rpt
report_clock_networks -file $out_dir/post_synth_clock_networks.rpt; # Show unconstrained clocks
report_clock_interaction -delay_type min_max -significant_digits 3 -file $out_dir/post_synth_clock_interaction.rpt; # Pay attention to Clock pair Classification, Inter-CLock Constraints, Path Requirement (WNS)
# xilinx::designutils::get_clock_interaction
report_high_fanout_nets -timing -load_type -max_nets $MAX_NET_PATH_NUM -file $out_dir/post_synth_fanout.rpt
# xilinx::designutils::insert_buffer -net $high_fanout_net -buffer {BUFG}
report_exceptions -ignored -file $out_dir/post_synth_exceptions.rpt; # -ignored -ignored_objects -write_valid_exceptions -write_merged_exceptions
report_disable_timing -file $out_dir/post_synth_disable_timing.rpt

# 1 LUT + 1 net have delay 0.5ns, if cycle period is Tns, logic level is 2T at most
# report_design_analysis -show_all -timing -max_paths $MAX_NET_PATH_NUM -file $out_dir/post_synth_design_timing.rpt
report_design_analysis -show_all -setup -max_paths $MAX_NET_PATH_NUM -file $out_dir/post_synth_design_setup_timing.rpt
# report_design_analysis -show_all -logic_level_dist_paths $MAX_NET_PATH_NUM -min_level $MIN_LOGIC_LEVEL -max_level $MAX_LOGIC_LEVEL -file $out_dir/post_synth_design_logic_level.rpt
report_design_analysis -show_all -logic_level_dist_paths $MAX_NET_PATH_NUM -logic_level_distribution -file $out_dir/post_synth_design_logic_level_dist.rpt

xilinx::designutils::report_failfast -detailed_reports synth -file $out_dir/post_synth_failfast.rpt

report_drc -file $out_dir/post_synth_drc.rpt
report_drc -ruledeck methodology_checks -file $out_dir/post_synth_drc_methodology.rpt
report_drc -ruledeck timing_checks -file $out_dir/post_synth_drc_timing.rpt
# Check unique control sets < 7.5% of total slices, at most 15%
report_control_sets -verbose -file $out_dir/post_synth_control_sets.rpt

# intra-clock skew < 300ps, inter-clock skew < 500ps

# Check 1) LUT on clock tree (TIMING-14), 2) hold constraints for multicycle path constraints (XDCH-1).
report_methodology -file $out_dir/post_synth_methodology.rpt
report_timing -max $MAX_NET_PATH_NUM -slack_lesser_than 0 -file $out_dir/post_synth_timing.rpt

report_compile_order -constraints -file $out_dir/post_synth_constraints.rpt; # Verify IP constraints included
report_utilization -file $out_dir/post_synth_util.rpt; # -cells -pblocks
report_cdc -file $out_dir/post_synth_cdc.rpt
report_clocks -file $out_dir/post_synth_clocks.rpt; # Verify clock settings

# Use IS_SEQUENTIAL for -from/-to
# Instantiate XPM_CDC modules
# write_xdc -force -exclude_physical -exclude_timing -constraints INVALID

report_qor_assessment -report_all_suggestions -csv_output_dir $out_dir/$RQA_DIR -file $out_dir/post_synth_qor_assess.rpt
report_qor_suggestions -report_all_suggestions -csv_output_dir $out_dir/$RQS_DIR -file $out_dir/post_synth_qor_suggest.rpt

should_start_gui $run_to $SYNTH_PHASE

####################################################################################################
# STEP#4: batch insert ila, run logic optimization, placement and physical logic optimization,
# write design checkpoint, report utilization and timing estimates
####################################################################################################
# source batch_insert_ila.tcl
# batch_insert_ila 1048576
place_design; # -directive Explore
# Optionally run optimization if there are timing violations after placement
if {$EN_PHYS_OPT} {
    if {should_run_phys_opt} {
        # phys_opt_design can run multiple times:
        # phys_opt_design -force_replication_on_nets
        # phys_opt_design -directive
        phys_opt_design; # -directive Explore
    }
}
write_checkpoint -force $out_dir/post_place.dcp
write_xdc -force $out_dir/post_place.xdc
write_xdc -force -constraints INVALID $out_dir/post_place_invalid.xdc

report_timing_summary -report_unconstrained -warn_on_violation -file $out_dir/post_place_timing_summary.rpt
report_methodology -file $out_dir/post_place_methodology.rpt
report_timing -max $MAX_NET_PATH_NUM -slack_lesser_than 0 -file $out_dir/post_place_timing.rpt
report_clock_utilization -file $out_dir/post_place_clock_util.rpt
report_utilization -file $out_dir/post_place_util.rpt; # -cells -pblocks -slr
report_high_fanout_nets -timing -load_type -max_nets $MAX_NET_PATH_NUM -file $out_dir/post_place_fanout.rpt

# xilinx::designutils::timing_report_to_verilog -of_objects [get_timing_paths -max_paths $MAX_NET_PATH_NUM]
xilinx::designutils::report_failfast -by_slr -detailed_reports impl -file $out_dir/post_place_failfast.rpt
set slr_nets [xilinx::designutils::get_inter_slr_nets]
set slr_nets_exclude_clock [filter $slr_nets "TYPE != GLOBAL_CLOCK"]
set slr_net_exclude_clock_num [llength $slr_nets_exclude_clock]
if {$slr_net_exclude_clock_num > 0} {
    report_timing -through $slr_nets_exclude_clock -nworst 1 -max $slr_net_exclude_clock_num -unique_pins -file $out_dir/post_place_slr_nets.rpt
}
should_start_gui $run_to $PLACE_PHASE

####################################################################################################
# STEP#5: run the router, write the post-route design checkpoint, report the routing
# status, report timing, power, and DRC, and finally save the Verilog netlist.
####################################################################################################
route_design; # -directive Explore

            # if {[get_property SLACK [get_timing_paths]] >= 0} {
            # if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] >= 0} {
            #     break; # Stop if timing closure
            # }
proc run_ppo {{output_dir} {num_iters 1} {enable_phys_opt 1}} {
    if {$enable_phys_opt} {
        for {set idx 0} {$idx < $num_iters} {incr idx} {
            if {should_run_phys_opt} {
                place_design -post_place_opt; # Better to run after route
                phys_opt_design; # -directive AggressiveFanoutOpt
                route_design; # -directive Explore
                report_timing_summary -file $output_dir/post_route_timing_summary_$idx.rpt
                write_checkpoint -force $output_dir/post_route_$idx.dcp
            }
        }
    }
}

run_ppo $out_dir $NUM_PHYS_OPT_ITERS $EN_PHYS_OPT
report_phys_opt -file $out_dir/post_route_phys_opt.rpt

write_checkpoint -force $out_dir/post_route_final.dcp
write_xdc -force $out_dir/post_route.xdc
write_xdc -force -constraints INVALID $out_dir/post_route_invalid.xdc

report_timing_summary -report_unconstrained -warn_on_violation -file $out_dir/post_route_timing_summary.rpt
report_timing -of_objects [get_timing_paths -hold -to [get_clocks $target_clks] -max_paths $MAX_NET_PATH_NUM -filter { LOGIC_LEVELS >= 4 && LOGIC_LEVELS <= 40 }] -file $out_dir/post_route_long_paths.rpt
report_methodology -file $out_dir/post_route_methodology.rpt
report_timing -max $MAX_NET_PATH_NUM -slack_lesser_than 0 -file $out_dir/post_route_timing.rpt

report_route_status -file $out_dir/post_route_status.rpt
report_drc -file $out_dir/post_route_drc.rpt
report_drc -ruledeck methodology_checks -file $out_dir/post_route_drc_methodology.rpt
report_drc -ruledeck timing_checks -file $out_dir/post_route_drc_timing.rpt
# Check unique control sets < 7.5% of total slices, at most 15%
report_control_sets -verbose -file $out_dir/post_route_control_sets.rpt

report_power -file $out_dir/post_route_power.rpt
report_power_opt -file $out_dir/post_route_power_opt.rpt
report_utilization -file $out_dir/post_route_util.rpt
report_utilization -slr -file $out_dir/post_route_util_slr.rpt
report_ram_utilization -detail -file $out_dir/post_route_ram_utils.rpt
# Check fanout < 25K
report_high_fanout_nets -timing -load_type -max_nets $MAX_NET_PATH_NUM -file $out_dir/post_route_fanout.rpt
report_carry_chains -file $out_dir/post_route_carry_chains.rpt

report_design_analysis -show_all -hold -max_paths $MAX_NET_PATH_NUM -file $out_dir/post_route_design_hold_timing.rpt
# Check initial estimated router congestion level no more than 5, type (global, long, short) and top cells
report_design_analysis -show_all -congestion -file $out_dir/post_route_congestion.rpt
# Check difficult modules (>15K cells) with high Rent Exponent (complex logic cone) >= 0.65 and/or Avg. Fanout >= 4
report_design_analysis -show_all -complexity -file $out_dir/post_route_complexity.rpt; # -hierarchical_depth
# If congested, check problematic cells using report_utilization -cells XXX
# If congested, try NetDelay* for UltraScale+, or try SpredLogic* for UltraScale in implementation strategy
report_datasheet -file $out_dir/post_route_datasheet.rpt

xilinx::designutils::report_failfast -detailed_reports impl -file $out_dir/post_route_failfast.rpt
set sll_nets [xilinx::designutils::get_sll_nets]
set sll_net_num [llength $sll_nets]
if {$sll_net_num > 0} {
    report_timing -through $sll_nets -nworst 1 -max $sll_net_num -unique_pins -file $out_dir/post_route_sll_nets.rpt
}

set installed_apps [tclapp::list_apps]
if {[string match "*xilinx::ultrafast*" $installed_apps]} {
    puts "xilinx::ultrafast already installed"
} else {
    tclapp::install ultrafast
}
xilinx::ultrafast::report_io_reg -verbose -file $out_dir/post_route_io_reg.rpt
xilinx::ultrafast::report_reset_signals -all -file $out_dir/post_route_reset_signals.rpt
xilinx::ultrafast::check_pll_connectivity -file $out_dir/post_route_pll.rpt

report_io -file $out_dir/post_route_io.rpt
report_pipeline_analysis -file $out_dir/post_route_pipeline.rpt
report_qor_assessment -report_all_suggestions -csv_output_dir $out_dir/$RQA_DIR -file $out_dir/post_route_qor_assess.rpt
report_qor_suggestions -report_all_suggestions -csv_output_dir $out_dir/$RQS_DIR -file $out_dir/post_route_qor_suggest.rpt
write_qor_suggestions -force -strategy_dir $out_dir/$RQS_DIR -tcl_output_dir $out_dir/$RQS_DIR

write_verilog -force $out_dir/post_impl_netlist.v -mode timesim -sdf_anno true

should_start_gui $run_to $ROUTE_PHASE

####################################################################################################
# STEP#6: generate a bitstream
####################################################################################################
if {!$ooc_synth} {
    write_bitstream -force $out_dir/top.bit
}
should_start_gui $run_to $ALL_PHASE
