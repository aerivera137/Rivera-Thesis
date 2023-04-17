# Exterior functions for hurricane
# -> Get wind speed
function get_windspeed()
    # Select wind speed of hurricane
    d_wind = TriangularDist(75,158,150) # lower limit, upper limit, most are Category 2
    ws = rand(d_wind)
    return ws
end
# -> Generate hurricane category + period (hours)
function generate_hurricane(time_periods)    
    # Duration of hurricane season (when a hurricane can occur)
    JUNE_1_DAY = 152 # hour: 2921
    NOV_30_DAY = 334 # hour: 8030
    # Select a day to have a hurricane (higher probability of occurring in September)
    hours_per_day = 24
    FIRST_DAY_SEPT = 244
    d_day = TriangularDist(JUNE_1_DAY,NOV_30_DAY,FIRST_DAY_SEPT) # upper limit, lower limit, most in September
    HURRICANE_DAY_START = rand(d_day) 
    HURRICANE_DAY_START = convert(Int64,round(HURRICANE_DAY_START))
    HURRICANE_HOUR_START = HURRICANE_DAY_START * hours_per_day
    # Set duration of outage 
    P_HURRICANE = HURRICANE_HOUR_START:(HURRICANE_HOUR_START+48)
    # Get wind speed
    wind_speed = get_windspeed()
    # Discretize wind speed into a category of hurricane (where 2/3 and 4/5 are combined)
    hurricane_category_boundaries = [75,96,111,130,157]
    category = searchsortedfirst(hurricane_category_boundaries, wind_speed) - 1
    return category, P_HURRICANE
end
# Processing inputs
# -> Microgrids
function process_MG_inputs(generators,zone)
    # Define sets of microgrids in each zone (1=East,2=North,3=South,4=West)
    MG_Zone = Vector{Int64}()

    for (i, row) in enumerate(eachrow(generators))
        if row[:Zone] == zone && (contains(row[:technology], "Microgrid_Solar_Moderate") || contains(row[:technology], "Microgrid_Diesel_Moderate")) 
            push!(MG_Zone, i)
        end
    end

    println("Microgrids in zone:")
    println(MG_Zone)

    return MG_Zone
end
# -> Transmission lines
function process_BL_inputs(inputs,generators)
    # Define sets of lines
    BL = Vector{Int64}()
    # Record portion of capacity that is built for transmission lines
    BL_1_capacity = 0
    BL_3_capacity = 0
    BL_5_capacity = 0

    for (i, row) in enumerate(eachrow(generators))
        # Add to set of generator indices
        # North-to-east line (East=1): add Network_lines index (1)
        if row[:Zone] == 1 && contains(row[:technology], "Underground_line") && row[:Existing_Cap_MW] > 0
            println("There is a North-to-East buried line!")
            push!(BL, 1)
            BL_1_capacity = generators[i,"Existing_Cap_MW"]
        end
        # North-to-south line (North=2): add Network_lines index (3)
        if row[:Zone] == 2 && contains(row[:technology], "Underground_line") && row[:Existing_Cap_MW] > 0
            println("There is a North-to-South buried line!")
            push!(BL, 3)
            BL_3_capacity = generators[i,"Existing_Cap_MW"]
        end
        # South-to-west line (West=4): add Network_lines index (5)
        if row[:Zone] == 4 && contains(row[:technology], "Underground_line") && row[:Existing_Cap_MW] > 0
            println("There is a South-to-West buried line!")
            push!(BL, 5)
            BL_5_capacity = generators[i,"Existing_Cap_MW"]
        end
    end

    return BL, BL_1_capacity, BL_3_capacity, BL_5_capacity
end
# -> Failure rates for each generator in each category of hurricane
function get_failure_rate(generators,gen,cat)
    column = "Cat_" * string(cat) * "_Failure_Rate"
    return generators[gen, column]
end
# -> Limit max microgrid power output when it's protecting a substation
function limit_mg_output!(mg,generators,inputs,P_HURRICANE,zone,num_MG,num_MG_Available)
    # Variability of all generators
    variability = inputs["pP_Max"]
    # Set the power output of the microgrid as limited by microgrids that failed
    for hour in P_HURRICANE
        inputs["pP_Max"][mg,hour] = variability[mg,hour] * (num_MG_Available/num_MG)
    end
end
# -> Modify the load in a zone that doesn't have a microgrid
function modify_load!(inputs,original_load,zone,P_HURRICANE,num_substations)
    # Modify load at each hour 
    for hour in P_HURRICANE
        # Un-serve demand in this zone for these hours 
        inputs["pD"][hour,zone] -= (1/num_substations)*original_load[hour,zone]
    end
end
# Main function: running hurricane simulation
function hurricane_sim!(model::Model, inputs::Dict)
    ####################################################################################################################################
    ############################################################## SET-UP ##############################################################
    ####################################################################################################################################
    println("Starting hurricane sim")
    #= NEED TO DEFINE: 
    - T (hours)
    - Z (zones)
    - G (all generators), UC (thermal gens), VRE (VREs); MG_East, MG_North, MG_South, MG_West (microgrids in each zone)
    - L (all lines), NVL (non-vulnerable lines), VL (vulnerable lines), BL (buried lines)
    =#

    T = 1:inputs["T"]
    G = 1:inputs["G"]
    UC = inputs["COMMIT"] 
    VRE = inputs["VRE"] 
    dfGen = inputs["dfGen"]
    MG_East = process_MG_inputs(dfGen,1)
    MG_North = process_MG_inputs(dfGen,2)
    MG_South = process_MG_inputs(dfGen,3)
    MG_West = process_MG_inputs(dfGen,4)
    Z = 1:inputs["Z"]
    L = 1:inputs["L"]
    # Process buried lines and capacities
    BL, BL_1_capacity, BL_3_capacity, BL_5_capacity = process_BL_inputs(inputs,dfGen)
    # Define percents of lines that are underground based on the cap size of each line
    BL_1 = BL_1_capacity / 523.1
    BL_3 = BL_3_capacity / 1013.265
    BL_5 = BL_5_capacity / 311.535
    # See which vulnerable lines are buried (difference between BL and possible buried lines (PVL))
    PVL = [1,3,5]
    VL = setdiff(BL,PVL) 
    # Non-vulnerable lines: north to west and south to east
    NVL = [2,4]

    # Copy the original demand profile as a reference
    original_load = copy(inputs["pD"])

    # Define substation failure rates
    Substation_FailRates = DataFrame(Category=[1,2,3,4,5], Failure_Rate=[0.000000626,0.002837392,0.002837392,0.269302475,0.269302475])

    # Define default transmission line failure rates
    TranLine_FailRates = DataFrame(Category=[1,2,3,4,5], Failure_Rate=[0.001005387,0.036422691,0.036422691,0.27497107,0.27497107])

    # Define vulnerable transmission line failure rates (20% more vulnerable than default)
    VulnLine_FailRates = DataFrame(Category=[1,2,3,4,5], Failure_Rate=[0.001206464,0.043707229,0.043707229,0.329965284,0.329965284])

    # Define buried transmission line failure rates
    BurLine_FailRates = DataFrame(Category=[1,2,3,4,5], Failure_Rate=[0,0,0,0.15841923,0.158419238])

    # Define diesel microgrid failure rates
    Microgrid_FailRates = DataFrame(Category=[1,2,3,4,5], Failure_Rate=[0,0,0,0.15841923,0.158419238])

    # Define an array of outage values for each UC generator (0 for no outage, 1 for outage)
    outages = zeros(length(T), length(G))  

    # Define an array of damage values for each transmission line (1 for no damage, 0 for damage)
    line_availability = ones(length(T), length(L))

    # Check if substations are secure, if not, some demand is unmet in that area
    function check_substations(z, MG_Zone, generators, original_load, P_HURRICANE, category)
        println("Checking substations in zone:")
        println(string(z))
        # Define peak demand in the zone (MW)
        peak_demand_in_zone = maximum(inputs["pD"][:, z])*1000
        println("Peak demand in zone:")
        println(string(peak_demand_in_zone))
        # Define number of substations in the zone based on peak demand, where all substations (except remainder) have 20 MW
        size_substation = 20
        num_Substations = trunc(Int,peak_demand_in_zone/size_substation) + convert(Int,rem(peak_demand_in_zone,size_substation)>0)
        println("Number of substations:")
        println(string(num_Substations))
        # Record capacity of remaining substation
        cap_remainder_substation = rem(peak_demand_in_zone,size_substation)
        # Record total capacity of microgrids in the zone
        cap_MG = 0
        for mg in MG_Zone
            cap_MG += dfGen[mg,"Existing_Cap_MW"]
        end
        println("Existing microgrid capacity:")
        println(string(cap_MG))
        # Define number of microgrids in each zone by dividing the total capacity among the size of the substations
        num_MG = floor.(Int, (cap_MG*1000) / size_substation)
        num_MG = convert(Int64,num_MG)
        println("Printing number of microgrids:")
        println(string(num_MG))
        # Check how many microgrids have failed in the hurricane (knowing there are only diesel microgrids in this system)
        MG_Failed = rand(Bernoulli(Microgrid_FailRates.Failure_Rate[category]),num_MG)
        num_MG_Failed = sum(MG_Failed)
        num_MG_Available = num_MG - num_MG_Failed
        println("Printing number of available microgrids:")
        println(string(num_MG_Available))
        # Check how many substations are not connected to substations 
        num_Vuln_Substations = num_Substations - num_MG_Available
        num_Vuln_Substations = convert(Int64,num_Vuln_Substations)
        if num_Vuln_Substations < 0
            num_Vuln_Substations = 0
        end
        println("Number of vulnerable substations:")
        println(string(num_Vuln_Substations))
        # Check how many substations have failed
        Substations_Failed = rand(Bernoulli(Substation_FailRates.Failure_Rate[category]),num_Vuln_Substations)
        num_Substations_Failed = sum(Substations_Failed)
        println("Printing number of substations that have failed:")
        println(string(num_Substations_Failed))

        # Un-serve demand in zone for failed substations
        for i in 1:num_Substations_Failed
            println("Original load:")
            println(inputs["pD"][P_HURRICANE, z])
            println("A substation has failed - modifying load")
            modify_load!(inputs, original_load, z, P_HURRICANE, num_Substations)
            println(inputs["pD"][P_HURRICANE, z])
        end

        # Limit microgrid capacity during the hurricane period if it's protecting a substation
        for mg in MG_Zone
            println("Limiting microgrid output")
            limit_mg_output!(mg,dfGen,inputs,P_HURRICANE,z,num_MG,num_MG_Available)
        end

        lost_load =  sum(original_load[:, z]) - sum(inputs["pD"][:, z])
        lost_load_hurricane =  sum(original_load[P_HURRICANE, z]) - sum(inputs["pD"][P_HURRICANE, z])
        return lost_load, lost_load_hurricane
    end
    # Function to apply damage to system components for a given category of hurricane
    function damage_sim(category,P_HURRICANE)
        println(string(first(P_HURRICANE)))
        println(string(last(P_HURRICANE)))
        println(string(category))
        # Change variability for variable renewable generators to 0 if there is an outage
        for g in VRE
            # Bernoulli draw returns 1 for generators with higher probability of outage
            if rand(Bernoulli(get_failure_rate(dfGen,g,category))) 
                # Force variability to zero for VREs that are out for the duration of the outage
                println("A VRE has failed - modifying variability")
                START = first(P_HURRICANE)
                END = last(P_HURRICANE)
                restoration_time = dfGen[g,"Hours_to_Restore"]
                outage_time = START:(END+restoration_time)
                inputs["pP_Max"][g,outage_time] .= 0
            end
        end

        # Update outage value for thermal UC generators to 1 if there is an outage
        for g in UC
            # Bernoulli draw returns 1 for generators with higher probability of outage
            if rand(Bernoulli(get_failure_rate(dfGen,g,category)))
                # Force generator to shut off for the duration of the outage
                println("A generator has failed - modifying commitment state")
                START = first(P_HURRICANE)
                END = last(P_HURRICANE)
                restoration_time = dfGen[g,"Hours_to_Restore"]
                outage_time = START:(END+restoration_time)
                outages[outage_time,g] .= 1
            end
        end
        
        # Check all substations for failure + protect demand if microgrids are available
        lost_load_z1, lost_load_z1_hurricane = check_substations(1,MG_East,dfGen,original_load,P_HURRICANE,category)
        lost_load_z2, lost_load_z2_hurricane = check_substations(2,MG_North,dfGen,original_load,P_HURRICANE,category)
        lost_load_z3, lost_load_z3_hurricane = check_substations(3,MG_South,dfGen,original_load,P_HURRICANE,category)
        lost_load_z4, lost_load_z4_hurricane = check_substations(4,MG_West,dfGen,original_load,P_HURRICANE,category)

        dfNSE = DataFrame(Lost_Load_Zone_1 = lost_load_z1, 
                          Lost_Load_Zone_2 = lost_load_z2, 
                          Lost_Load_Zone_3 = lost_load_z3,
                          Lost_Load_Zone_4 = lost_load_z4)

        dfNSEHurricane = DataFrame(Lost_Load_Zone_1 = lost_load_z1_hurricane, 
                                    Lost_Load_Zone_2 = lost_load_z2_hurricane, 
                                    Lost_Load_Zone_3 = lost_load_z3_hurricane,
                                    Lost_Load_Zone_4 = lost_load_z4_hurricane)

        # Check for transmission line failure
        # Default/non-vulnerable lines
        for l in NVL
            # Check for failure
            if rand(Bernoulli(TranLine_FailRates.Failure_Rate[category])) 
                # If failed, cut off power flow in this line during the hurricane
                println("A less-vulnerable transmission line has failed - modifying power flow")
                START = first(P_HURRICANE)
                END = last(P_HURRICANE)
                restoration_time = 336 # two weeks = 336 hours
                outage_time = START:(END+restoration_time)
                line_availability[outage_time,l] .= 0
            end
        end
        # Vulnerable lines
        for l in VL  
            # Check for failure
            if rand(Bernoulli(VulnLine_FailRates.Failure_Rate[category])) 
                # If failed, cut off power flow in this line during the hurricane
                println("A vulnerable transmission line has failed - modifying power flow")
                START = first(P_HURRICANE)
                END = last(P_HURRICANE)
                restoration_time = 336 # two weeks = 336 hours
                outage_time = START:(END+restoration_time)
                line_availability[outage_time,l] .= 0
            end
        end
        # Buried lines
        println("Checking buried lines")
        for l in BL
            START = first(P_HURRICANE)
            END = last(P_HURRICANE)
            restoration_time = 336 # two weeks = 336 hours
            outage_time = START:(END+restoration_time)
            # Check for failure (these lines are in the generators data set)
            if l == 1
                println("Checking north-south buried line")
                failed_BL_portion = (BL_1)*rand(Bernoulli(BurLine_FailRates.Failure_Rate[category]))
                failed_VL_portion = (1-BL_1)*rand(Bernoulli(VulnLine_FailRates.Failure_Rate[category])) 
                line_availability[outage_time,l] .= 1 - (failed_BL_portion+failed_VL_portion)
            elseif l == 3
                println("Checking north-east buried line")
                failed_BL_portion = (BL_3)*rand(Bernoulli(BurLine_FailRates.Failure_Rate[category]))
                failed_VL_portion = (1-BL_3)*rand(Bernoulli(VulnLine_FailRates.Failure_Rate[category])) 
                line_availability[outage_time,l] .= 1 - (failed_BL_portion+failed_VL_portion)
            elseif l == 5
                println("Checking south-west buried line")
                failed_BL_portion = (BL_5)*rand(Bernoulli(BurLine_FailRates.Failure_Rate[category]))
                failed_VL_portion = (1-BL_5)*rand(Bernoulli(VulnLine_FailRates.Failure_Rate[category])) 
                line_availability[outage_time,l] .= 1 - (failed_BL_portion+failed_VL_portion)
            end
        end

        # Define an array with just the indices of UC generators that have outages
        #outage_indices = findall(x -> x == 1, outages)   
        return outages, line_availability, dfNSE, dfNSEHurricane
    end
    ####################################################################################################################################
    ############################################################ SIMULATION ############################################################
    ####################################################################################################################################
    # Generate hurricane period and category
    category, P_HURRICANE = generate_hurricane(T)

    # Call damage function (main function)
    outages, line_availability, dfNSE, dfNSEHurricane = damage_sim(category, P_HURRICANE)

    # Return results
    dfCategory = DataFrame(Category = [category])
    dfPHurricane = DataFrame(HurricanePeriod = [P_HURRICANE])

    println("Returning outputs")
    return dfCategory, dfPHurricane, outages, line_availability, dfNSE, dfNSEHurricane
end