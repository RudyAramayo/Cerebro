import argparse
import os
import shutil
from ultralytics import YOLO
import blobconverter

def main():
    parser = argparse.ArgumentParser(description="Automated continuous spatial learning pipeline for Cerebro.")
    parser.add_argument("--project", required=True, help="Name of the game/project to train (e.g., Chess, Monopoly)")
    args = parser.parse_args()

    # Paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    datasets_dir = os.path.abspath(os.path.join(script_dir, "..", "Datasets"))
    project_dir = os.path.join(datasets_dir, args.project)
    yaml_path = os.path.join(project_dir, "data.yaml")

    if not os.path.exists(yaml_path):
        print(f"Error: Project '{args.project}' dataset not found at {project_dir}")
        return

    print(f"--- Starting Automated Training for Project: {args.project} ---")
    
    # Load lightweight YOLOv8 Nano model for Edge deployment
    model = YOLO("yolov8n.pt")
    
    # Train the model
    # We use device="mps" to utilize Apple Silicon GPU acceleration locally!
    print("1. Fine-tuning YOLOv8 model on new spatial data...")
    results = model.train(
        data=yaml_path,
        epochs=50,
        imgsz=640,
        device="mps",
        project=os.path.join(project_dir, "runs"),
        name="train",
        exist_ok=True # Overwrites latest run
    )
    
    best_weights = os.path.join(project_dir, "runs", "train", "weights", "best.pt")
    if not os.path.exists(best_weights):
        print("Error: Training failed to produce best.pt weights.")
        return

    # Export to ONNX
    print("2. Exporting trained model to ONNX format...")
    export_model = YOLO(best_weights)
    onnx_path = export_model.export(format="onnx", imgsz=[400, 640], opset=12)
    
    # Compile to Myriad X .blob using Luxonis blobconverter
    print("3. Compiling ONNX to Myriad X .blob for OAK-D Pro hardware...")
    try:
        blob_path = blobconverter.from_onnx(
            model=onnx_path,
            shaves=6,
            use_su_tool=False,
            optimizer_params=[
                "--mean_values=[0,0,0]",
                "--scale_values=[255,255,255]"
            ],
            output_dir=os.path.join(script_dir, "Models")
        )
        
        # Rename the generic generated blob to the project specific name
        final_blob_path = os.path.join(script_dir, "Models", f"{args.project.lower()}_6shave.blob")
        if os.path.exists(final_blob_path):
            os.remove(final_blob_path)
        os.rename(blob_path, final_blob_path)
        print(f"\nSUCCESS! Deployed new upgraded spatial brain to: {final_blob_path}")
        
    except Exception as e:
        print(f"Failed to compile blob: {e}")

if __name__ == "__main__":
    main()
