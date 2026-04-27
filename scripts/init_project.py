import os
from cookiecutter.main import cookiecutter
from git import Repo

def create_and_init_project(template_url, output_dir="."):
    # 1. Generate project from Cookiecutter
    # This returns the path to the newly created project folder
    project_path = cookiecutter(
        template_url,
        output_dir=output_dir,
        no_input=False,  # Set to True if using a config file for full automation
    )
    
    print(f"Project created at: {project_path}")

    # 2. Initialize Git Repository
    repo = Repo.init(project_path)
    
    # 3. Add all files and Commit
    repo.index.add("*")
    repo.index.commit("initial commit: project scaffolded from template")
    
    print("Git repository initialized with initial commit.")
    
    # 4. (Optional) Link to Remote
    # repo.create_remote('origin', 'https://github.com')
    # repo.remotes.origin.push('master:master')

if __name__ == "__main__":
    TEMPLATE = "https://github.com"
    create_and_init_project(TEMPLATE)
