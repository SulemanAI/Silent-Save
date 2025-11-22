import os
import sys
from PIL import Image

def process_image(input_path, output_size=(256, 256)):
    """
    Converts an image to PNG and resizes it to the specified dimensions.
    """
    try:
        # Validate input file exists
        if not os.path.exists(input_path):
            print(f"Error: The file '{input_path}' was not found.")
            return

        # Open the image
        with Image.open(input_path) as img:
            print(f"Processing: {input_path}")
            print(f"Original size: {img.size}")

            # Convert to RGBA: This ensures we don't lose transparency data 
            # and fixes issues with palette-based images (like GIFs or simple PNGs)
            img = img.convert("RGBA")

            # Resize the image
            # Image.Resampling.LANCZOS is used for high-quality downsampling/upsampling
            resized_img = img.resize(output_size, Image.Resampling.LANCZOS)

            # Generate output filename
            # Replaces the original extension with .png and adds _1024 suffix
            base_name = os.path.splitext(input_path)[0]
            output_path = f"{base_name}_256.png"

            # Save the new image
            resized_img.save(output_path, "PNG")
            
            print(f"Success! Image saved to: {output_path}")
            print(f"New size: {resized_img.size}")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    # USAGE:
    # You can run this script directly or change the variable below.
    
    # Replace 'input_image.jpg' with the path to your actual file
    target_file = r"C:\Users\cv\Desktop\SilentSave\assets\icon.png"
    
    # Check if the user passed a file via command line arguments
    # Example: python image_converter.py myphoto.bmp
    if len(sys.argv) > 1:
        target_file = sys.argv[1]

    process_image(target_file)