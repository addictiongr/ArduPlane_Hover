// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

//****************************************************************
// Function that controls aileron/rudder, elevator, rudder (if 4 channel control) and throttle to produce desired attitude and airspeed.
//****************************************************************


/*
  get a speed scaling number for control surfaces. This is applied to
  PIDs to change the scaling of the PID with speed. At high speed we
  move the surfaces less, and at low speeds we move them more.
 */
static float get_speed_scaler(void)
{
    float aspeed, speed_scaler;
    if (ahrs.airspeed_estimate(&aspeed)) {
        if (aspeed > 0) {
            speed_scaler = g.scaling_speed / aspeed;
        } else {
            speed_scaler = 2.0;
        }
        speed_scaler = constrain(speed_scaler, 0.5, 2.0);
    } else {
        if (g.channel_throttle.servo_out > 0) {
            speed_scaler = 0.5 + ((float)THROTTLE_CRUISE / g.channel_throttle.servo_out / 2.0);                 // First order taylor expansion of square root
            // Should maybe be to the 2/7 power, but we aren't goint to implement that...
        }else{
            speed_scaler = 1.67;
        }
        // This case is constrained tighter as we don't have real speed info
        speed_scaler = constrain(speed_scaler, 0.6, 1.67);
    }
    return speed_scaler;
}

/*
  return true if the current settings and mode should allow for stick mixing
 */
static bool stick_mixing_enabled(void)
{
    if (control_mode == CIRCLE || control_mode > FLY_BY_WIRE_B) {
        // we're in an auto mode. Check the stick mixing flag
        if (g.stick_mixing &&
            geofence_stickmixing() &&
            failsafe == FAILSAFE_NONE) {
            // we're in an auto mode, and haven't triggered failsafe
            return true;
        } else {
            return false;
        }
    }
    // non-auto mode. Always do stick mixing
    return true;
}


static void stabilize()
{
    float ch1_inf = 1.0;
    float ch2_inf = 1.0;
    float ch4_inf = 1.0;
    float speed_scaler = get_speed_scaler();

    if(crash_timer > 0) {
        nav_roll_cd = 0;
    }

    if (inverted_flight) {
        // we want to fly upside down. We need to cope with wrap of
        // the roll_sensor interfering with wrap of nav_roll, which
        // would really confuse the PID code. The easiest way to
        // handle this is to ensure both go in the same direction from
        // zero
        nav_roll_cd += 18000;
        if (ahrs.roll_sensor < 0) nav_roll_cd -= 36000;
    }

#if APM_CONTROL == DISABLED
	
	// Use quaternions for hover mode //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	if (control_mode == HOVER_PID || control_mode == HOVER_PID_REFERENCE || control_mode == HOVER_ADAPTIVE) {
		roll_PID_input = roll_error_centdeg;
	}	else {
		roll_PID_input = (nav_roll_cd - ahrs.roll_sensor);
	}
	g.channel_roll.servo_out = g.pidServoRoll.get_pid(roll_PID_input, speed_scaler);
	g.channel_roll.servo_out = constrain(g.channel_roll.servo_out, -SERVO_MAX, SERVO_MAX); // Added constrain to prevent runaway PWM rates

	// Calculate dersired servo output for the roll
	// ---------------------------------------------
	//g.channel_roll.servo_out = g.pidServoRoll.get_pid((nav_roll_cd - ahrs.roll_sensor), speed_scaler);

	// Use quaternions for hover mode ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	if (control_mode == HOVER_PID || control_mode == HOVER_PID_REFERENCE || control_mode == HOVER_ADAPTIVE) {
		pitch_PID_input = pitch_error_centdeg;
	}	else {	
		int32_t tempcalc = nav_pitch_cd +
				fabs(ahrs.roll_sensor * g.kff_pitch_compensation) +
				(g.channel_throttle.servo_out * g.kff_throttle_to_pitch) -
				(ahrs.pitch_sensor - g.pitch_trim_cd);
		if (inverted_flight) {
			// when flying upside down the elevator control is inverted
			tempcalc = -tempcalc;
		}
		pitch_PID_input = tempcalc;
	}
	g.channel_pitch.servo_out = g.pidServoPitch.get_pid(pitch_PID_input, speed_scaler);
	g.channel_pitch.servo_out = constrain(g.channel_pitch.servo_out, -SERVO_MAX, SERVO_MAX); // Added constrain to prevent runaway PWM rates
	///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	//g.channel_pitch.servo_out = g.pidServoPitch.get_pid(tempcalc, speed_scaler);
#else // APM_CONTROL == ENABLED
    // calculate roll and pitch control using new APM_Control library
	g.channel_roll.servo_out = g.rollController.get_servo_out(nav_roll_cd, speed_scaler, control_mode == STABILIZE);
	g.channel_pitch.servo_out = g.pitchController.get_servo_out(nav_pitch_cd, speed_scaler, control_mode == STABILIZE);    
#endif

    // Mix Stick input to allow users to override control surfaces
    // -----------------------------------------------------------
    if (stick_mixing_enabled()) {
        if (control_mode < FLY_BY_WIRE_A || control_mode > FLY_BY_WIRE_C) {
            // do stick mixing on aileron/elevator if not in a fly by
            // wire mode
            ch1_inf = (float)g.channel_roll.radio_in - (float)g.channel_roll.radio_trim;
            ch1_inf = fabs(ch1_inf);
            ch1_inf = min(ch1_inf, 400.0);
            ch1_inf = ((400.0 - ch1_inf) /400.0);

            ch2_inf = (float)g.channel_pitch.radio_in - g.channel_pitch.radio_trim;
            ch2_inf = fabs(ch2_inf);
            ch2_inf = min(ch2_inf, 400.0);
            ch2_inf = ((400.0 - ch2_inf) /400.0);
            
            // scale the sensor input based on the stick input
            // -----------------------------------------------
            g.channel_roll.servo_out *= ch1_inf;
            g.channel_pitch.servo_out *= ch2_inf;
            
            // Mix in stick inputs
            // -------------------
            g.channel_roll.servo_out +=     g.channel_roll.pwm_to_angle();
            g.channel_pitch.servo_out +=    g.channel_pitch.pwm_to_angle();
        }

        // stick mixing performed for rudder for all cases including FBW
        // important for steering on the ground during landing
        // -----------------------------------------------
        ch4_inf = (float)g.channel_rudder.radio_in - (float)g.channel_rudder.radio_trim;
        ch4_inf = fabs(ch4_inf);
        ch4_inf = min(ch4_inf, 400.0);
        ch4_inf = ((400.0 - ch4_inf) /400.0);
    }

	// Apply output to Rudder
	// ----------------------
	calc_nav_yaw(speed_scaler, ch4_inf);
	g.channel_rudder.servo_out *= ch4_inf;
	g.channel_rudder.servo_out += g.channel_rudder.pwm_to_angle();

	// Call slew rate limiter if used
	// ------------------------------
	//#if(ROLL_SLEW_LIMIT != 0)
	//	g.channel_roll.servo_out = roll_slew_limit(g.channel_roll.servo_out);
	//#endif
}

static void crash_checker()
{
    if(ahrs.pitch_sensor < -4500) {
        crash_timer = 255;
    }
    if(crash_timer > 0)
        crash_timer--;
}


static void calc_throttle()
{
    if (!alt_control_airspeed()) {
        int16_t throttle_target = g.throttle_cruise + throttle_nudge;

        // TODO: think up an elegant way to bump throttle when
        // groundspeed_undershoot > 0 in the no airspeed sensor case; PID
        // control?

        // no airspeed sensor, we use nav pitch to determine the proper throttle output
        // AUTO, RTL, etc
        // ---------------------------------------------------------------------------
        if (nav_pitch_cd >= 0) {
            g.channel_throttle.servo_out = throttle_target + (g.throttle_max - throttle_target) * nav_pitch_cd / g.pitch_limit_max_cd;
        } else {
            g.channel_throttle.servo_out = throttle_target - (throttle_target - g.throttle_min) * nav_pitch_cd / g.pitch_limit_min_cd;
        }

        g.channel_throttle.servo_out = constrain(g.channel_throttle.servo_out, g.throttle_min.get(), g.throttle_max.get());
    } else {
        // throttle control with airspeed compensation
        // -------------------------------------------
        energy_error = airspeed_energy_error + altitude_error_cm * 0.098f;

        // positive energy errors make the throttle go higher
        g.channel_throttle.servo_out = g.throttle_cruise + g.pidTeThrottle.get_pid(energy_error);
        g.channel_throttle.servo_out += (g.channel_pitch.servo_out * g.kff_pitch_to_throttle);

        g.channel_throttle.servo_out = constrain(g.channel_throttle.servo_out,
                                                 g.throttle_min.get(), g.throttle_max.get());
    }

}

////////////////////////////////////////////////////////////////////////////I added this/////////////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////// All of these functions were added by me ///////////////////////////////////////////////////////////////////////////////////

/*****************************************
* Calculate throttle setting during hover (in fast freq loop) 
*****************************************/
static void calc_throttle_hover()
{
	int32_t throttle_diverge;
	int32_t throttle_sink;
	int32_t throttle_hover;
	
	/********************************
	Divegence throttle control logic
	*********************************/
	// Check for divergence criteria in yaw and pitch axis only (ignore roll direction, it will take care of itself)
	check_pitch_diverge();
	check_yaw_diverge();

	if (diverge_pitch || diverge_yaw) {
	throttle_diverge = int16_t (g.throttle_max * DIVERGENCE_THROTTLE_MAX);
	} else {
		throttle_diverge = int16_t (g.throttle_max * DIVERGENCE_THROTTLE_MIN);  // min and max values defined in APM_Config.h
	}
	

	/********************************
	Sink rate throttle control logic
	*********************************/
	// Set desired sink rate
	int32_t sink_rate_cd  = int32_t ((g.channel_throttle.control_in - 50)*((float)SINK_RATE_MAX/50)*(100)); //Command is in centimeters/second since thats what altitude readings are in
	// SINK_RATE_MAX is the maximum commanded magnitude of the sink/climb rate defined in m/s in APM_Config.h
	int32_t sink_rate_error = sink_rate_cd - sink_rate;

	// Use total energy error PID values to command sink rate
	throttle_sink = g.pidTeThrottle.get_pid(sink_rate_error, 1.0 , true);  // Dont need to scale input because AMP code uses 0-100 throttle instead of 0-1 like me, so using cm/sec as an input gives correct 0-100 scale with same gains 
		// use positive_I_only = true so that integrator terms is limited to 0 -> IMAX instead of -IMAX -> IMAX 

	// Pick maximum throttle setting to send to servo
	if (throttle_diverge > throttle_sink) {
		throttle_hover = throttle_diverge;
	} else {
		throttle_hover = throttle_sink;
	}

	g.channel_throttle.servo_out = constrain(throttle_hover, g.throttle_min.get(), g.throttle_max.get());
}

static void calc_sink_rate()
{
// Calculate current sink rate
	uint32_t tnow = millis();    
	uint32_t dt = tnow - last_t_alt;
    float delta_time;

	if (last_t_alt == 0 || dt > 1000) {        
		dt = 0; //reset dt if lots of time has passed and on first switching into hover mode
	}

    last_t_alt = tnow;
    delta_time = (float)dt / 1000.0f; //in seconds
	
	
	// Compute derivative component if time has elapsed    
	if (dt > 0) {
		float derivative;

		if (isnan(last_derivative_alt)) {
			// we've just done a reset, suppress the first derivative
			// term as we don't want a sudden change in input to cause
			// a large D output change			
			derivative = 0;
			last_derivative_alt = 0;
		} else {

			derivative = (float (current_loc.alt - last_alt)) / delta_time;
		}

	// discrete low pass filter, cuts out the        
	// high frequency noise that can drive the controller crazy
        float RC = 1/(2*PI*_fCut_alt);  // cutoff frequency _fCut_alt set in APM_Config.h
        derivative = last_derivative_alt +
                     ((delta_time / (RC + delta_time)) *
                      (derivative - last_derivative_alt));

        // update state
        last_derivative_alt    = derivative;
		last_alt = current_loc.alt;	

		sink_rate = int32_t (derivative);  // sink rate in centimeters/second
	}
	// if no time has passed or if dt gets reset, dont change value of sink_rate
}

static void check_pitch_diverge()
{
	double angle_max = DIVERGENCE_ANGLE;
	
	if (diverge_pitch) {
    // Airplane has already diverged in pitch axis
		if (fabs(double (pitch_error*(180/PI)))  <= angle_max) { // Note: need to do check based on pitch_error and not pitch_error deg because the later gets changed by the adaptive controller and blows up even when error is small
			diverge_pitch = false;
		} else {
			diverge_pitch = true;
		}
	} else {
		// Airplane hasnt converged yet so check for divergence
		if (fabs(double (pitch_error*(180/PI))) > angle_max) { // Note: need to do check based on pitch_error and not pitch_error deg because the later gets changed by the adaptive controller and blows up even when error is small
			diverge_pitch = true;
		} else {
			diverge_pitch = false;
		}
	}
}

static void check_yaw_diverge()
{
	double angle_max = DIVERGENCE_ANGLE;
	
	if (diverge_yaw) {
    // Airplane has already diverged in pitch axis
		if (fabs(double (yaw_error*(180/PI)))  <= angle_max) { // Note: need to do check based on yaw_error and not yaw_error deg because the later gets changed by the adaptive controller and blows up even when error is small
			diverge_yaw = false;
		} else {
			diverge_yaw = true;
		}
	} else {
		// Airplane hasnt converged yet so check for divergence
		if (fabs(double (yaw_error*(180/PI))) > angle_max) {  // Note: need to do check based on yaw_error and not yaw_error deg because the later gets changed by the adaptive controller and blows up even when error is small
			diverge_yaw = true;
		} else {
			diverge_yaw = false;
		}
	}
}


/*****************************************
* Calcuate pitch reference model output (in fast freq loop)
*****************************************/
float pitch_reference_model() {
	// time variable
	uint32_t tnow = millis();    
	uint32_t dt = tnow - t_start_hover;
    float delta_time = (float)dt / 1000.0f; //in seconds

	float theta;

if (ZETA <= 0) { //no damping
	theta = pitch_final + cos(delta_time*OMEGA_N)*(pitch_init-pitch_final);

} else if (ZETA > 0 && ZETA < 1) { //under damped 
	theta = pitch_final + exp(-delta_time*OMEGA_N*ZETA)*(pitch_init - pitch_final) *
		(cos(delta_time*OMEGA_N*sqrt(1-pow(ZETA,2))) - (
		 ((sin(delta_time*OMEGA_N*sqrt(1-pow(ZETA,2))))*(OMEGA_N*ZETA - (2*pitch_init*OMEGA_N*ZETA - 2*pitch_final*OMEGA_N*ZETA)/(pitch_init - pitch_final))) / 
		 (OMEGA_N*sqrt(1-pow(ZETA,2)))
		 ));

} else if (ZETA == 1) { //over damped
	theta = pitch_final + exp(-delta_time * OMEGA_N)*(pitch_init - pitch_final) + delta_time * exp(-delta_time * OMEGA_N)*(pitch_init*OMEGA_N - pitch_final*OMEGA_N);

} else if (ZETA > 1) { // critically damped 
	theta = pitch_final + exp(-delta_time*OMEGA_N*ZETA)*(pitch_init - pitch_final) *
		(cosh(delta_time*OMEGA_N*sqrt(pow(ZETA,2)-1)) - (
		 ((sinh(delta_time*OMEGA_N*sqrt(pow(ZETA,2)-1)))*(OMEGA_N*ZETA - (2*pitch_init*OMEGA_N*ZETA - 2*pitch_final*OMEGA_N*ZETA)/(pitch_init - pitch_final))) / 
		 (OMEGA_N*sqrt(pow(ZETA,2)-1))
		 ));
} else {
	theta = 0; 
}

return (theta);
}


/*****************************************
* Calcuate Gdot for adaptive controller(in fast freq loop) 
*****************************************/
static void calc_Gdot(float e_roll, float e_pitch, float e_yaw) {
	
	Vector3f e_y(e_roll, e_pitch, e_yaw);  //initialize error vector

	Vector3f row1, row2, row3; // set up rows of e_y*e_y' matrix

	// multiply error vector by its transpose e_y*ey'
	row1 = e_y*e_y.x;
	row2 = e_y*e_y.y;
	row3 = e_y*e_y.z;

	Matrix3f ey_ey(row1, row2, row3); // create and populate e_y*e_y' matrix

	Matrix3f temp = ey_ey * H; 

	Gdot = temp * (-1.0);  // Gdot = - e_y' * e_y * H 

	// Test for correct sign on G0
	//Gdot.zero();  // if Gdot = zeros then there should be no modification to e_y and should get same results as PID controller

}

static void integrate_Gdot() {
	uint32_t tnow = millis();
    uint32_t dt = tnow - last_t_G;
    //float output            = 0;
    float delta_time;

    if (last_t_G == 0 || dt > 1000) {
        dt = 0;

		// Adaptive controler hasn't been used for a full second then zero
		// the intergator term. This prevents I buildup from a
		// previous fight mode from causing a massive return before
		// the integrator gets a chance to correct itself
		//_integrator = 0;
    }
    last_t_G = tnow;

    delta_time = (float)dt / 1000.0;
	
	G += Gdot * delta_time;
}

static void calc_adaptive_output(float& e_roll, float& e_pitch, float& e_yaw) { // passed errors by reference so that I can change their value without having to create new variables
	
	Vector3f e_y(e_roll, e_pitch, e_yaw);  //initialize error vector

	Vector3f temp = G * e_y; 

	// Reassign error values after doing adaptive manipulation
	e_roll = temp.x;
	e_pitch = temp.y;
	e_yaw = temp.z;

}
///////////////////////////////////////////////////////////////////////// End of custom functions I added///////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/*****************************************
* Calculate desired roll/pitch/yaw angles (in medium freq loop)
*****************************************/

//  Yaw is separated into a function for future implementation of heading hold on rolling take-off
// ----------------------------------------------------------------------------------------
static void calc_nav_yaw(float speed_scaler, float ch4_inf)
{
    if (hold_course != -1) {
        // steering on or close to ground
        g.channel_rudder.servo_out = g.pidWheelSteer.get_pid(bearing_error_cd, speed_scaler) + 
            g.kff_rudder_mix * g.channel_roll.servo_out;
        return;
    }

#if APM_CONTROL == DISABLED
	/////////////////////////////////////////////////////////////////// I added this stuff//////////////////////////////////////////////////////////////////////////////////////////////////
	if (control_mode == HOVER_PID || control_mode == HOVER_PID_REFERENCE || control_mode == HOVER_ADAPTIVE) {  
		
		g.channel_rudder.servo_out = g.pidServoRudder.get_pid(yaw_error_centdeg, speed_scaler);
		g.channel_rudder.servo_out = constrain(g.channel_rudder.servo_out, -SERVO_MAX, SERVO_MAX);  // Added constrain to prevent runaway PWM rates
		////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	}	else {
    // always do rudder mixing from roll
    g.channel_rudder.servo_out = g.kff_rudder_mix * g.channel_roll.servo_out;

    // a PID to coordinate the turn (drive y axis accel to zero)
    Vector3f temp = imu.get_accel();
    int32_t error = -temp.y*100.0;
	
    g.channel_rudder.servo_out += g.pidServoRudder.get_pid(error, speed_scaler);
	}

#else // APM_CONTROL == ENABLED
    // use the new APM_Control library
	g.channel_rudder.servo_out = g.yawController.get_servo_out(speed_scaler, ch4_inf < 0.25) + g.channel_roll.servo_out * g.kff_rudder_mix;
#endif
}


static void calc_nav_pitch()
{
    // Calculate the Pitch of the plane
    // --------------------------------
    if (alt_control_airspeed()) {
        nav_pitch_cd = -g.pidNavPitchAirspeed.get_pid(airspeed_error_cm);
    } else {
        nav_pitch_cd = g.pidNavPitchAltitude.get_pid(altitude_error_cm);
    }
    nav_pitch_cd = constrain(nav_pitch_cd, g.pitch_limit_min_cd.get(), g.pitch_limit_max_cd.get());
}


static void calc_nav_roll()
{
#define NAV_ROLL_BY_RATE 0
#if NAV_ROLL_BY_RATE
    // Scale from centidegrees (PID input) to radians per second. A P gain of 1.0 should result in a
    // desired rate of 1 degree per second per degree of error - if you're 15 degrees off, you'll try
    // to turn at 15 degrees per second.
    float turn_rate = ToRad(g.pidNavRoll.get_pid(bearing_error_cd) * .01);

    // Use airspeed_cruise as an analogue for airspeed if we don't have airspeed.
    float speed;
    if (!ahrs.airspeed_estimate(&speed)) {
        speed = g.airspeed_cruise_cm*0.01;

        // Floor the speed so that the user can't enter a bad value
        if(speed < 6) {
            speed = 6;
        }
    }

    // Bank angle = V*R/g, where V is airspeed, R is turn rate, and g is gravity.
    nav_roll = ToDeg(atan(speed*turn_rate/9.81)*100);

#else
    // this is the old nav_roll calculation. We will use this for 2.50
    // then remove for a future release
    float nav_gain_scaler = 0.01 * g_gps->ground_speed / g.scaling_speed;
    nav_gain_scaler = constrain(nav_gain_scaler, 0.2, 1.4);
    nav_roll_cd = g.pidNavRoll.get_pid(bearing_error_cd, nav_gain_scaler); //returns desired bank angle in degrees*100
#endif

    nav_roll_cd = constrain(nav_roll_cd, -g.roll_limit_cd.get(), g.roll_limit_cd.get());
}


/*****************************************
* Roll servo slew limit
*****************************************/
/*
 *  float roll_slew_limit(float servo)
 *  {
 *       static float last;
 *       float temp = constrain(servo, last-ROLL_SLEW_LIMIT * delta_ms_fast_loop/1000.f, last + ROLL_SLEW_LIMIT * delta_ms_fast_loop/1000.f);
 *       last = servo;
 *       return temp;
 *  }*/

/*****************************************
* Throttle slew limit
*****************************************/
static void throttle_slew_limit()
{
    static int16_t last = 1000;
    if(g.throttle_slewrate) {                   // if slew limit rate is set to zero then do not slew limit

        float temp = g.throttle_slewrate * G_Dt * 10.f;                 //  * 10 to scale % to pwm range of 1000 to 2000
        g.channel_throttle.radio_out = constrain(g.channel_throttle.radio_out, last - (int)temp, last + (int)temp);
        last = g.channel_throttle.radio_out;
    }
}


/* We want to supress the throttle if we think we are on the ground and in an autopilot controlled throttle mode.

   Disable throttle if following conditions are met:
   *       1 - We are in Circle mode (which we use for short term failsafe), or in FBW-B or higher
   *       AND
   *       2 - Our reported altitude is within 10 meters of the home altitude.
   *       3 - Our reported speed is under 5 meters per second.
   *       4 - We are not performing a takeoff in Auto mode
   *       OR
   *       5 - Home location is not set
*/
static bool suppress_throttle(void)
{
    if (!throttle_suppressed) {
        // we've previously met a condition for unsupressing the throttle
        return false;
    }
    if (control_mode != CIRCLE && control_mode <= FLY_BY_WIRE_A) {
        // the user controls the throttle
        throttle_suppressed = false;
        return false;
    }

    if (control_mode==AUTO && takeoff_complete == false) {
        // we're in auto takeoff 
        throttle_suppressed = false;
        return false;
    }
    
    if (labs(home.alt - current_loc.alt) >= 1000) {
        // we're more than 10m from the home altitude
        throttle_suppressed = false;
        return false;
    }

	
	if (g_gps != NULL && 
		g_gps->status() == GPS::GPS_OK && 
		g_gps->ground_speed >= 500) {
		// we're moving at more than 5 m/s
		throttle_suppressed = false;
		return false;        
	}

    // throttle remains suppressed
    return true;
}

/*****************************************
* Set the flight control servos based on the current calculated values
*****************************************/
static void set_servos(void)
{
    int16_t flapSpeedSource = 0;

    if(control_mode == MANUAL) {
        // do a direct pass through of radio values
        if (g.mix_mode == 0) {
            g.channel_roll.radio_out                = g.channel_roll.radio_in;
            g.channel_pitch.radio_out               = g.channel_pitch.radio_in;
        } else {
            g.channel_roll.radio_out                = APM_RC.InputCh(CH_ROLL);
            g.channel_pitch.radio_out               = APM_RC.InputCh(CH_PITCH);
        }
        g.channel_throttle.radio_out    = g.channel_throttle.radio_in;
        g.channel_rudder.radio_out              = g.channel_rudder.radio_in;

        // ensure flaps and extra aileron channels are updated
        RC_Channel_aux::set_radio(RC_Channel_aux::k_aileron, g.channel_roll.radio_out);
        RC_Channel_aux::copy_radio_in_out(RC_Channel_aux::k_flap_auto);

        if (g.mix_mode != 0) {
            // set any differential spoilers to follow the elevons in
            // manual mode. 
            RC_Channel_aux::set_radio(RC_Channel_aux::k_dspoiler1, g.channel_roll.radio_out);
            RC_Channel_aux::set_radio(RC_Channel_aux::k_dspoiler2, g.channel_pitch.radio_out);
        }
    } else {
        if (g.mix_mode == 0) {
            RC_Channel_aux::set_servo_out(RC_Channel_aux::k_aileron, g.channel_roll.servo_out);
        }else{
            /*Elevon mode*/
            float ch1;
            float ch2;
            ch1 = g.channel_pitch.servo_out - (BOOL_TO_SIGN(g.reverse_elevons) * g.channel_roll.servo_out);
            ch2 = g.channel_pitch.servo_out + (BOOL_TO_SIGN(g.reverse_elevons) * g.channel_roll.servo_out);

			/* Differential Spoilers
               If differential spoilers are setup, then we translate
               rudder control into splitting of the two ailerons on
               the side of the aircraft where we want to induce
               additional drag.
             */
			if (RC_Channel_aux::function_assigned(RC_Channel_aux::k_dspoiler1) && RC_Channel_aux::function_assigned(RC_Channel_aux::k_dspoiler2)) {
				float ch3 = ch1;
				float ch4 = ch2;
				if ( BOOL_TO_SIGN(g.reverse_elevons) * g.channel_rudder.servo_out < 0) {
				    ch1 += abs(g.channel_rudder.servo_out);
				    ch3 -= abs(g.channel_rudder.servo_out);
				} else {
					ch2 += abs(g.channel_rudder.servo_out);
				    ch4 -= abs(g.channel_rudder.servo_out);
				}
				RC_Channel_aux::set_servo_out(RC_Channel_aux::k_dspoiler1, ch3);
				RC_Channel_aux::set_servo_out(RC_Channel_aux::k_dspoiler2, ch4);
			}

            // directly set the radio_out values for elevon mode
            g.channel_roll.radio_out  =     elevon1_trim + (BOOL_TO_SIGN(g.reverse_ch1_elevon) * (ch1 * 500.0/ SERVO_MAX));
            g.channel_pitch.radio_out =     elevon2_trim + (BOOL_TO_SIGN(g.reverse_ch2_elevon) * (ch2 * 500.0/ SERVO_MAX));
        }

        if (control_mode >= FLY_BY_WIRE_B) {
            /* only do throttle slew limiting in modes where throttle
             *  control is automatic */
            throttle_slew_limit();
        }

#if OBC_FAILSAFE == ENABLED
        // this is to allow the failsafe module to deliberately crash 
        // the plane. Only used in extreme circumstances to meet the
        // OBC rules
        if (obc.crash_plane()) {
            g.channel_roll.servo_out = -4500;
            g.channel_pitch.servo_out = -4500;
            g.channel_rudder.servo_out = -4500;
            g.channel_throttle.servo_out = 0;
        }
#endif
        

        // push out the PWM values
        if (g.mix_mode == 0) {
            g.channel_roll.calc_pwm();
            g.channel_pitch.calc_pwm();
        }
        g.channel_rudder.calc_pwm();

#if THROTTLE_OUT == 0
        g.channel_throttle.servo_out = 0;
#else
        // convert 0 to 100% into PWM
        g.channel_throttle.servo_out = constrain(g.channel_throttle.servo_out, 
                                                 g.throttle_min.get(), 
                                                 g.throttle_max.get());

        if (suppress_throttle()) {
            g.channel_throttle.servo_out = 0;
            if (g.throttle_suppress_manual) {
                // manual pass through of throttle while throttle is suppressed
                g.channel_throttle.radio_out = g.channel_throttle.radio_in;
            } else {
                g.channel_throttle.calc_pwm();                
            }
        } else {
            g.channel_throttle.calc_pwm();
        }
#endif
    }

    // Auto flap deployment
    if(control_mode < FLY_BY_WIRE_B) {
        RC_Channel_aux::copy_radio_in_out(RC_Channel_aux::k_flap_auto);
    } else if (control_mode >= FLY_BY_WIRE_B) {
        // FIXME: use target_airspeed in both FBW_B and g.airspeed_enabled cases - Doug?
        if (control_mode == FLY_BY_WIRE_B) {
            flapSpeedSource = target_airspeed_cm * 0.01;
        } else if (airspeed.use()) {
            flapSpeedSource = g.airspeed_cruise_cm * 0.01;
        } else {
            flapSpeedSource = g.throttle_cruise;
        }
        if ( g.flap_1_speed != 0 && flapSpeedSource > g.flap_1_speed) {
            RC_Channel_aux::set_servo_out(RC_Channel_aux::k_flap_auto, 0);
        } else if (g.flap_2_speed != 0 && flapSpeedSource > g.flap_2_speed) {
            RC_Channel_aux::set_servo_out(RC_Channel_aux::k_flap_auto, g.flap_1_percent);
        } else {
            RC_Channel_aux::set_servo_out(RC_Channel_aux::k_flap_auto, g.flap_2_percent);
        }
    }

#if HIL_MODE == HIL_MODE_DISABLED || HIL_SERVOS
    // send values to the PWM timers for output
    // ----------------------------------------
    APM_RC.OutputCh(CH_1, g.channel_roll.radio_out);     // send to Servos
    APM_RC.OutputCh(CH_2, g.channel_pitch.radio_out);     // send to Servos
    APM_RC.OutputCh(CH_3, g.channel_throttle.radio_out);     // send to Servos
    APM_RC.OutputCh(CH_4, g.channel_rudder.radio_out);     // send to Servos
    // Route configurable aux. functions to their respective servos
    g.rc_5.output_ch(CH_5);
    g.rc_6.output_ch(CH_6);
    g.rc_7.output_ch(CH_7);
    g.rc_8.output_ch(CH_8);
 # if CONFIG_APM_HARDWARE != APM_HARDWARE_APM1
    g.rc_9.output_ch(CH_9);
    g.rc_10.output_ch(CH_10);
    g.rc_11.output_ch(CH_11);
 # endif
#endif
}

static void demo_servos(byte i) {

    while(i > 0) {
        gcs_send_text_P(SEVERITY_LOW,PSTR("Demo Servos!"));
#if HIL_MODE == HIL_MODE_DISABLED || HIL_SERVOS
        APM_RC.OutputCh(1, 1400);
        mavlink_delay(400);
        APM_RC.OutputCh(1, 1600);
        mavlink_delay(200);
        APM_RC.OutputCh(1, 1500);
#endif
        mavlink_delay(400);
        i--;
    }
}

// return true if we should use airspeed for altitude/throttle control
static bool alt_control_airspeed(void)
{
    return airspeed.use() && g.alt_control_algorithm == ALT_CONTROL_DEFAULT;
}
