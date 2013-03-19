#!/bin/bash 
set -e

# Requirements for this script
#  installed versions of: FSL5.0.1 or later, gradunwarp python package (from MGH)
#  environment: FSLDIR and PATH for gradient_unwarp.py

################################################ SUPPORT FUNCTIONS ##################################################

Usage() {
  echo "`basename $0`: Script for performing gradient-nonlinearity and susceptibility-inducted distortion correction on T1w and T2w images, then also registering T2w to T1w"
  echo " "
  echo "Usage: `basename $0` [--workingdir=<working directory>]"
  echo "            --t1=<input T1w image>"
  echo "            --t1brain=<input T1w brain-extracted image>"
  echo "            --t2=<input T2w image>"
  echo "            --t2brain=<input T2w brain-extracted image>"
  echo "            --fmapmag=<input fieldmap magnitude image>"
  echo "            --fmapphase=<input fieldmap phase images (single 4D image containing 2x3D volumes)>"
  echo "            --echodiff=<echo time difference for fieldmap images (in milliseconds)>"
  echo "            --t1sampspacing=<sample spacing (readout direction) of T1w image - in seconds>"
  echo "            --t2sampspacing=<sample spacing (readout direction) of T2w image - in seconds>"
  echo "            --unwarpdir=<direction of distortion according to voxel axes (post reorient2std)>"
  echo "            --ot1=<output corrected T1w image>"
  echo "            --ot1brain=<output corrected, brain-extracted T1w image>"
  echo "            --ot1warp=<output warpfield for distortion correction of T1w image>"
  echo "            --ot2=<output corrected T2w image>"
  echo "            --ot2brain=<output corrected, brain-extracted T2w image>"
  echo "            --ot2warp=<output warpfield for distortion correction of T2w image>"
  echo "            [--gdcoeffs=<gradient distortion coefficients (SIEMENS file)>]"
}

# function for parsing options
getopt1() {
    sopt="$1"
    shift 1
    for fn in $@ ; do
	if [ `echo $fn | grep -- "^${sopt}=" | wc -w` -gt 0 ] ; then
	    echo $fn | sed "s/^${sopt}=//"
	    return 0
	fi
    done
}

defaultopt() {
    echo $1
}

################################################### OUTPUT FILES #####################################################

# For distortion correction:
#
# Output files (in $WD): Magnitude  Magnitude_brain  Phase  FieldMap
#                        Magnitude_brain_warppedT1w  Magnitude_brain_warppedT1w2${TXwImageBrainBasename}
#                        fieldmap2${T1wImageBrainBasename}.mat   FieldMap2${T1wImageBrainBasename}
#                        FieldMap2${T1wImageBrainBasename}_ShiftMap  
#                        FieldMap2${T1wImageBrainBasename}_Warp ${T1wImageBasename}  ${T1wImageBrainBasename}
#        Plus the versions with T1w -> T2w
#
# Output files (not in $WD):  ${OutputT1wTransform}   ${OutputT1wImage}  ${OutputT1wImageBrain}
#        Note that these outputs are actually copies of the last three entries in the $WD list
#
#
# For registration:
#
# Output images (in $WD/T2w2T1w):  sqrtT1wbyT2w  T2w_reg.mat  T2w_reg_init.mat
#                                  T2w_dc_reg  (the warp field)
#                                  T2w_reg     (the warped image)
# Output images (not in $WD):  ${OutputT2wTransform}   ${OutputT2wImage}
#        Note that these outputs are copies of the last two images (respectively) from the T2w2T1w subdirectory

################################################## OPTION PARSING #####################################################

# Just give usage if no arguments specified
if [ $# -eq 0 ] ; then Usage; exit 0; fi
# check for correct options
if [ $# -lt 17 ] ; then Usage; exit 1; fi

# parse arguments
WD=`getopt1 "--workingdir" $@`  # "$1"
T1wImage=`getopt1 "--t1" $@`  # "$2"
T1wImageBrain=`getopt1 "--t1brain" $@`  # "$3"
T2wImage=`getopt1 "--t2" $@`  # "$4"
T2wImageBrain=`getopt1 "--t2brain" $@`  # "$5"
MagnitudeInputName=`getopt1 "--fmapmag" $@`  # "$6"
PhaseInputName=`getopt1 "--fmapphase" $@`  # "$7"
TE=`getopt1 "--echodiff" $@`  # "$8"
T1wSampleSpacing=`getopt1 "--t1sampspacing" $@`  # "$9"
T2wSampleSpacing=`getopt1 "--t2sampspacing" $@`  # "${10}"
UnwarpDir=`getopt1 "--unwarpdir" $@`  # "${11}"
OutputT1wImage=`getopt1 "--ot1" $@`  # "${12}"
OutputT1wImageBrain=`getopt1 "--ot1brain" $@`  # "${13}"
OutputT1wTransform=`getopt1 "--ot1warp" $@`  # "${14}"
OutputT2wImage=`getopt1 "--ot2" $@`  # "${15}"
OutputT2wTransform=`getopt1 "--ot2warp" $@`  # "${16}"
#GlobalScripts=`getopt1 "--globalscripts" $@`  # "${17}"
GradientDistortionCoeffs=`getopt1 "--gdcoeffs" $@`  # "${18}"

# default parameters
GlobalScripts=${HCPPIPEDIR_Global}
WD=`defaultopt $WD .`

T1wImage=`${FSLDIR}/bin/remove_ext $T1wImage`
T1wImageBrain=`${FSLDIR}/bin/remove_ext $T1wImageBrain`
T2wImage=`${FSLDIR}/bin/remove_ext $T2wImage`
T2wImageBrain=`${FSLDIR}/bin/remove_ext $T2wImageBrain`

T1wImageBrainBasename=`basename "$T1wImageBrain"`
T1wImageBasename=`basename "$T1wImage"`
T2wImageBrainBasename=`basename "$T2wImageBrain"`
T2wImageBasename=`basename "$T2wImage"`

Modalities="T1w T2w"
UsingT2=true
if [ X$T2wImageBasename = X ] ; then
    Modalities="T1w"   # This is the minimum that must be run
    UsingT2=false
fi

echo " "
echo " START: T2wToT1wDistortionCorrectionAndReg"

mkdir -p $WD
mkdir -p ${WD}/FieldMap

# Record the input options in a log file
echo "$0 $@" >> $WD/log.txt
echo "PWD = `pwd`" >> $WD/log.txt
echo "date: `date`" >> $WD/log.txt
echo " " >> $WD/log.txt


########################################## DO WORK ########################################## 

### Create fieldmaps (and apply gradient non-linearity distortion correction)
echo " "
echo " "
echo " "
#echo ${GlobalScripts}/FieldMapPreprocessingAll.sh ${WD}/FieldMap ${MagnitudeInputName} ${PhaseInputName} ${TE} ${WD}/Magnitude ${WD}/Magnitude_brain ${WD}/Phase ${WD}/FieldMap ${GradientDistortionCoeffs} ${GlobalScripts}

${GlobalScripts}/FieldMapPreprocessingAll.sh \
    --workingdir=${WD}/FieldMap \
    --fmapmag=${MagnitudeInputName} \
    --fmapphase=${PhaseInputName} \
    --echodiff=${TE} \
    --ofmapmag=${WD}/Magnitude \
    --ofmapmagbrain=${WD}/Magnitude_brain \
    --ophase=${WD}/Phase \
    --ofmap=${WD}/FieldMap \
    --gdcoeffs=${GradientDistortionCoeffs}
    #${GlobalScripts} 


### LOOP over available modalities ###

for TXw in $Modalities ; do
    # set up required variables
    if [ $TXw = T1w ] ; then
	TXwImage=$T1wImage
	TXwImageBrain=$T1wImageBrain
	TXwSampleSpacing=$T1wSampleSpacing
	TXwImageBasename=$T1wImageBasename
	TXwImageBrainBasename=$T1wImageBrainBasename
    else
	TXwImage=$T2wImage
	TXwImageBrain=$T2wImageBrain
	TXwSampleSpacing=$T2wSampleSpacing
	TXwImageBasename=$T2wImageBasename
	TXwImageBrainBasename=$T2wImageBrainBasename
    fi

    # Forward warp the fieldmap magnitude and register to TXw image (transform phase image too)
    # MJ QUERY: Is --icorr really safe here?  The distortions will be pretty minor though, so it probably does little...
    ${FSLDIR}/bin/fugue -v -i ${WD}/Magnitude_brain.nii.gz --icorr --unwarpdir=${UnwarpDir} --dwell=$TXwSampleSpacing --loadfmap=${WD}/FieldMap.nii.gz -w ${WD}/Magnitude_brain_warpped${TXw}

    ${FSLDIR}/bin/flirt -dof 6 -in ${WD}/Magnitude_brain_warpped${TXw} -ref ${TXwImageBrain} -out ${WD}/Magnitude_brain_warpped${TXw}2${TXwImageBrainBasename} -omat ${WD}/fieldmap2${TXwImageBrainBasename}.mat 
    ${FSLDIR}/bin/flirt -in ${WD}/FieldMap.nii.gz -ref ${TXwImageBrain} -applyxfm -init ${WD}/fieldmap2${TXwImageBrainBasename}.mat -out ${WD}/FieldMap2${TXwImageBrainBasename} 
    
    # Convert to shift map then to warp field and unwarp the TXw
    ${FSLDIR}/bin/fugue --loadfmap=${WD}/FieldMap2${TXwImageBrainBasename} --dwell=${TXwSampleSpacing} --saveshift=${WD}/FieldMap2${TXwImageBrainBasename}_ShiftMap.nii.gz    
    ${FSLDIR}/bin/convertwarp --relout --rel --ref=${TXwImageBrain} --shiftmap=${WD}/FieldMap2${TXwImageBrainBasename}_ShiftMap.nii.gz --shiftdir=${UnwarpDir} --out=${WD}/FieldMap2${TXwImageBrainBasename}_Warp.nii.gz    
    ${FSLDIR}/bin/applywarp --rel --interp=spline -i ${TXwImage} -r ${TXwImage} -w ${WD}/FieldMap2${TXwImageBrainBasename}_Warp.nii.gz -o ${WD}/${TXwImageBasename}
    
    # Make a brain image (transform to make a mask, then apply it)
    ${FSLDIR}/bin/applywarp --rel --interp=nn -i ${TXwImageBrain} -r ${TXwImageBrain} -w ${WD}/FieldMap2${TXwImageBrainBasename}_Warp.nii.gz -o ${WD}/${TXwImageBrainBasename}
    
    ${FSLDIR}/bin/fslmaths ${WD}/${TXwImageBasename} -mas ${WD}/${TXwImageBrainBasename} ${WD}/${TXwImageBrainBasename}
    
    # Copy files to specified destinations
    if [ $TXw = T1w ] ; then 
       ${FSLDIR}/bin/imcp ${WD}/FieldMap2${TXwImageBrainBasename}_Warp ${OutputT1wTransform}
       ${FSLDIR}/bin/imcp ${WD}/${TXwImageBasename} ${OutputT1wImage}
       ${FSLDIR}/bin/imcp ${WD}/${TXwImageBrainBasename} ${OutputT1wImageBrain}
    fi
    
done

### END LOOP over modalities ###


### Now do T2w to T1w registration
if [ $UsingT2 = true ] ; then
    mkdir -p ${WD}/T2w2T1w
    
    # Main registration: between corrected T2w and corrected T1w
    # MJ QUERY: Change to FSL5.0.1 version?  Will this need correction for SE fieldmaps?
    ${FSLDIR}/bin/epi_reg --epi=${WD}/${T2wImageBrainBasename} --t1=${WD}/${T1wImageBasename} --t1brain=${WD}/${T1wImageBrainBasename} --out=${WD}/T2w2T1w/T2w_reg
    
    # Make a warpfield directly from original (non-corrected) T2w to corrected T1w  (and apply it)
    ${FSLDIR}/bin/convertwarp --relout --rel --ref=${T1wImage} --warp1=${WD}/FieldMap2${T2wImageBrainBasename}_Warp.nii.gz --postmat=${WD}/T2w2T1w/T2w_reg.mat -o ${WD}/T2w2T1w/T2w_dc_reg
    
    ${FSLDIR}/bin/applywarp --rel --interp=spline --in=${T2wImage} --ref=${T1wImage} --warp=${WD}/T2w2T1w/T2w_dc_reg --out=${WD}/T2w2T1w/T2w_reg
    
    # Add 1 to avoid exact zeros within the image (a problem for myelin mapping?)
    ${FSLDIR}/bin/fslmaths ${WD}/T2w2T1w/T2w_reg.nii.gz -add 1 ${WD}/T2w2T1w/T2w_reg.nii.gz -odt float

    # QA image
    ${FSLDIR}/bin/fslmaths ${WD}/T2w2T1w/T2w_reg -mul ${T1wImage} -sqrt ${WD}/T2w2T1w/sqrtT1wbyT2w -odt float
    
    # Copy files to specified destinations
    ${FSLDIR}/bin/imcp ${WD}/T2w2T1w/T2w_dc_reg ${OutputT2wTransform}
    ${FSLDIR}/bin/imcp ${WD}/T2w2T1w/T2w_reg ${OutputT2wImage}
fi

echo " "
echo " END: T2wToT1wDistortionCorrectionAndReg"
echo " END: `date`" >> $WD/log.txt

########################################## QA STUFF ########################################## 

if [ -e $WD/qa.txt ] ; then rm -f $WD/qa.txt ; fi
echo "cd `pwd`" >> $WD/qa.txt
if [ $UsingT2 = true ] ; then
    echo "# View registration result of corrected T2w to corrected T1w image: showing both images + sqrt(T1w*T2w)" >> $WD/qa.txt
    echo "fslview ${OutputT1wImage} ${OutputT2wImage} ${WD}/T2w2T1w/sqrtT1wbyT2w" >> $WD/qa.txt
fi
echo "# Compare pre- and post-distortion correction for T1w" >> $WD/qa.txt
echo "fslview ${T1wImage} ${OutputT1wImage}" >> $WD/qa.txt
if [ $UsingT2 = true ] ; then
    echo "# Compare pre- and post-distortion correction for T2w" >> $WD/qa.txt
    echo "fslview ${T2wImage} ${WD}/${T2wImageBasename}" >> $WD/qa.txt
fi

##############################################################################################

