FROM gcr.io/deeplearning-platform-release/pytorch-gpu.1-13.py310

RUN git clone https://github.com/facebookresearch/detectron2.git
RUN python -m pip install -e detectron2
# RUN python -m pip install 'git+https://github.com/facebookresearch/detectron2.git'

WORKDIR /detectron2
ENTRYPOINT ["sleep", "infinity"]
# ENTRYPOINT ["python", "tools/train_net.py", "--config-file", "./configs/COCO-InstanceSegmentation/mask_rcnn_R_50_FPN_1x.yaml", "--num-gpus", "2", "SOLVER.IMS_PER_BATCH", "32", "SOLVER.BASE_LR", "0.0025", "DATALOADER.NUM_WORKERS", "16", "SOLVER.MAX_ITER", "10000"]